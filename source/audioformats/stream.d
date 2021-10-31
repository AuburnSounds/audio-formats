/**
Audio decoder and encoder abstraction. This delegates to format-specific encoders/decoders.

Copyright: Guillaume Piolats 2020.
License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
*/
module audioformats.stream;

import core.stdc.stdio;
import core.stdc.string;
import core.stdc.stdlib: malloc, realloc, free;

import dplug.core.nogc;
import dplug.core.vec;

import audioformats.io;

version(decodeMP3)  import audioformats.minimp3_ex;
version(decodeFLAC) import audioformats.drflac;
version(decodeOGG)  import audioformats.vorbis;
version(decodeOPUS) import audioformats.dopus;
version(decodeMOD)  import audioformats.pocketmod;

version(decodeWAV) import audioformats.wav;
else version(encodeWAV) import audioformats.wav;

version(decodeXM) import audioformats.libxm;

/// Library for sound file decoding and encoding.
/// All operations are blocking, and should not be done in a real-time audio thread.
/// (besides, you would also need resampling for playback).
/// Also not thread-safe, synchronization in on yours.

/// Format of audio files.
enum AudioFileFormat
{
    wav,  /// WAVE format
    mp3,  /// MP3  format
    flac, /// FLAC format
    ogg,  /// OGG  format
    opus, /// Opus format
    mod,  /// ProTracker MOD format
    xm,   /// FastTracker II Extended Module format
    unknown
}

/// Returns: String representation of an `AudioFileFormat`.
string convertAudioFileFormatToString(AudioFileFormat fmt)
{
    final switch(fmt) with (AudioFileFormat)
    {
        case wav:     return "wav";
        case mp3:     return "mp3";
        case flac:    return "flac";
        case ogg:     return "ogg";
        case opus:    return "opus";
        case mod:     return "mod";
        case xm:      return "xm";
        case unknown: return "unknown";
    }
}


/// The length of things you shouldn't query a length about:
///    - files that are being written
///    - audio files you don't know the extent
enum audiostreamUnknownLength = -1;

/// An AudioStream is a pointer to a dynamically allocated `Stream`.
public struct AudioStream
{
public: // This is also part of the public API


    /// Opens an audio stream that decodes from a file.
    /// This stream will be opened for reading only.
    ///
    /// Params: 
    ///     path An UTF-8 path to the sound file.
    ///
    /// Note: throws a manually allocated exception in case of error. Free it with `dplug.core.destroyFree`.
    void openFromFile(const(char)[] path) @nogc
    {
        cleanUp();

        fileContext = mallocNew!FileContext();
        fileContext.initialize(path, false);
        userData = fileContext;

        _io = mallocNew!IOCallbacks();
        _io.seek          = &file_seek;
        _io.tell          = &file_tell;
        _io.getFileLength = &file_getFileLength;
        _io.read          = &file_read;
        _io.write         = null;
        _io.skip          = &file_skip;
        _io.flush         = null;

        startDecoding();
    }

    /// Opens an audio stream that decodes from memory.
    /// This stream will be opened for reading only.
    /// Note: throws a manually allocated exception in case of error. Free it with `dplug.core.destroyFree`.
    ///
    /// Params: inputData The whole file to decode.
    void openFromMemory(const(ubyte)[] inputData) @nogc
    {
        cleanUp();

        memoryContext = mallocNew!MemoryContext();
        memoryContext.initializeWithConstantInput(inputData.ptr, inputData.length);

        userData = memoryContext;

        _io = mallocNew!IOCallbacks();
        _io.seek          = &memory_seek;
        _io.tell          = &memory_tell;
        _io.getFileLength = &memory_getFileLength;
        _io.read          = &memory_read;
        _io.write         = null;
        _io.skip          = &memory_skip;
        _io.flush         = null;

        startDecoding();
    }

    /// Opens an audio stream that writes to file.
    /// This stream will be opened for writing only.
    /// Note: throws a manually allocated exception in case of error. Free it with `dplug.core.destroyFree`.
    ///
    /// Params: 
    ///     path An UTF-8 path to the sound file.
    ///     format Audio file format to generate.
    ///     sampleRate Sample rate of this audio stream. This samplerate might be rounded up to the nearest integer number.
    ///     numChannels Number of channels of this audio stream.
    void openToFile(const(char)[] path, AudioFileFormat format, float sampleRate, int numChannels) @nogc
    {
        cleanUp();
        
        fileContext = mallocNew!FileContext();
        fileContext.initialize(path, true);
        userData = fileContext;

        _io = mallocNew!IOCallbacks();
        _io.seek          = &file_seek;
        _io.tell          = &file_tell;
        _io.getFileLength = null;
        _io.read          = null;
        _io.write         = &file_write;
        _io.skip          = null;
        _io.flush         = &file_flush;

        startEncoding(format, sampleRate, numChannels);
    }

    /// Opens an audio stream that writes to a dynamically growable output buffer.
    /// This stream will be opened for writing only.
    /// Access to the internal buffer after encoding with `finalizeAndGetEncodedResult`.
    /// Note: throws a manually allocated exception in case of error. Free it with `dplug.core.destroyFree`.
    ///
    /// Params: 
    ///     format Audio file format to generate.
    ///     sampleRate Sample rate of this audio stream. This samplerate might be rounded up to the nearest integer number.
    ///     numChannels Number of channels of this audio stream.
    void openToBuffer(AudioFileFormat format, float sampleRate, int numChannels) @nogc
    {
        cleanUp();

        memoryContext = mallocNew!MemoryContext();
        memoryContext.initializeWithInternalGrowableBuffer();
        userData = memoryContext;

        _io = mallocNew!IOCallbacks();
        _io.seek          = &memory_seek;
        _io.tell          = &memory_tell;
        _io.getFileLength = null;
        _io.read          = null;
        _io.write         = &memory_write_append;
        _io.skip          = null;
        _io.flush         = &memory_flush;

        startEncoding(format, sampleRate, numChannels);
    }

    /// Opens an audio stream that writes to a pre-defined area in memory of `maxLength` bytes.
    /// This stream will be opened for writing only.
    /// Destroy this stream with `closeAudioStream`.
    /// Note: throws a manually allocated exception in case of error. Free it with `dplug.core.destroyFree`.
    ///
    /// Params: 
    ///     data Pointer to output memory.
    ///     size_t maxLength.
    ///     format Audio file format to generate.
    ///     sampleRate Sample rate of this audio stream. This samplerate might be rounded up to the nearest integer number.
    ///     numChannels Number of channels of this audio stream.
    void openToMemory(ubyte* data, 
                      size_t maxLength,
                      AudioFileFormat format,
                      float sampleRate, 
                      int numChannels) @nogc
    {
        cleanUp();

        memoryContext = mallocNew!MemoryContext();
        memoryContext.initializeWithExternalOutputBuffer(data, maxLength);
        userData = memoryContext;

        _io = mallocNew!IOCallbacks();
        _io.seek          = &memory_seek;
        _io.tell          = &memory_tell;
        _io.getFileLength = null;
        _io.read          = null;
        _io.write         = &memory_write_limited;
        _io.skip          = null;
        _io.flush         = &memory_flush;

        startEncoding(format, sampleRate, numChannels);
    }

    /// Returns: `true` if using this stream's operations is acceptable in an audio thread (eg: no file I/O).
    bool realtimeSafe() @nogc
    {
        return fileContext is null;
    }

    ~this() @nogc
    {
        cleanUp();
    }

    void cleanUp() @nogc
    {
        // Write the last needed bytes if needed
        finalizeEncodingIfNeeded();

        version(decodeMP3)
        {
            if (_mp3DecoderNew !is null)
            {
                mp3dec_ex_close(_mp3DecoderNew);
                free(_mp3DecoderNew);
                _mp3DecoderNew = null;
            }
            if (_mp3io !is null)
            {
                free(_mp3io);
                _mp3io = null;
            }
        }

        version(decodeFLAC)
        {
            if (_flacDecoder !is null)
            {
                drflac_close(_flacDecoder);
                _flacDecoder = null;
            }
        }

        version(decodeOGG)
        {
            if (_oggDecoder !is null)
            {
                destroyFree(_oggDecoder);
                _oggDecoder = null;
            }
            _oggBuffer.reallocBuffer(0);
        }

        version(decodeOPUS)
        {
            if (_opusDecoder !is null)
            {
                opusClose(_opusDecoder);
                _opusDecoder = null;
            }
            _opusBuffer = null;
        }

        version(decodeWAV)
        {
            if (_wavDecoder !is null)
            {
                destroyFree(_wavDecoder);
                _wavDecoder = null;
            }
        }

        version(decodeXM)
        {
            if (_xmDecoder !is null)
            {
                xm_free_context(_xmDecoder);
                _xmDecoder = null;
            }
            if (_xmContent != null)
            {
                free(_xmContent);
                _xmContent = null;
            }
        }

        version(decodeMOD)
        {
            if (_modDecoder !is null)
            {
                free(_modDecoder);
                _modDecoder = null;
                _modContent.reallocBuffer(0);
            }
        }

        version(encodeWAV)
        {
            if (_wavEncoder !is null)
            {
                destroyFree(_wavEncoder);
                _wavEncoder = null;
            }
        }

        if (_decoderContext)
        {
            destroyFree(_decoderContext);
            _decoderContext = null;
        }

        if (fileContext !is null)
        {
            if (fileContext.file !is null)
            {
                int result = fclose(fileContext.file);
                if (result)
                    throw mallocNew!Exception("Closing of audio file errored");
            }
            destroyFree(fileContext);
            fileContext = null;
        }

        if (memoryContext !is null)
        {
            // TODO destroy buffer if any is owned
            destroyFree(memoryContext);
            memoryContext = null;
        }

        if (_io !is null)
        {
            destroyFree(_io);
            _io = null;
        }
    }

    /// Returns: File format of this stream.
    AudioFileFormat getFormat() nothrow @nogc
    {
        return _format;
    }

    /// Returns: Number of channels in this stream. 1 means mono, 2 means stereo...
    int getNumChannels() nothrow @nogc
    {
        return _numChannels;
    }

    /// Returns: Length of this stream in frames.
    /// Note: may return the special value `audiostreamUnknownLength` if the length is unknown.
    long getLengthInFrames() nothrow @nogc
    {
        return _lengthInFrames;
    }

    /// Returns: Sample-rate of this stream in Hz.
    float getSamplerate() nothrow @nogc
    {
        return _sampleRate;
    }

    /// Read interleaved float samples in the given buffer `outData`.
    /// 
    /// Params:
    ///     outData Buffer where to put decoded samples. Samples are arranged in an interleaved fashion.
    ///     frames The number of frames to be read.
    ///
    /// Returns: Number of actually read frames. Multiply by `getNumChannels()` to get the number of read samples.
    ///          When that number is less than `frames`, it means the stream is done decoding, or that there was a decoding error.
    ///
    /// TODO: once this returned less than `frames`, are we guaranteed we can keep calling that and it returns 0?
    int readSamplesFloat(float* outData, int frames) @nogc
    {
        // If you fail here, you are using this `AudioStream` for decoding:
        // - after it has been destroyed,
        // - or it was created for encoding instead 
        assert(_io && _io.read !is null);

        final switch(_format)
        {
            case AudioFileFormat.opus:
            {
                version(decodeOPUS)
                {
                    try
                    {
                        int decoded = 0;
                        while (decoded < frames)
                        {
                            // Is there any sample left in _opusBuffer?
                            // If not decode some frames.
                            if (_opusBuffer is null || _opusBuffer.length == 0)
                            {
                                _opusBuffer = _opusDecoder.readFrame();
                                if (_opusBuffer is null)
                                    break;
                            }

                            int samplesInBuffer = cast(int) _opusBuffer.length;
                            int framesInBuffer  = samplesInBuffer / _numChannels;
                            if (framesInBuffer == 0)
                                break;

                            // Frames to pull are min( frames left to decode, frames available)
                            int framesToDecode = frames - decoded;
                            int framesToUse = framesToDecode < framesInBuffer ? framesToDecode : framesInBuffer;
                            assert(framesToUse != 0);

                            int samplesToUse = framesToUse * _numChannels;
                            int outOffset = decoded*_numChannels;
                            for (int n = 0; n < samplesToUse; ++n)
                            {
                                outData[outOffset + n] = _opusBuffer[n] / 32767.0f;
                            }
                            _opusBuffer = _opusBuffer[samplesToUse..$]; // reduce size of intermediate buffer
                            decoded += framesToUse;
                        }
                            return decoded;
                    }
                    catch(Exception e)
                    {
                        destroyFree(e);
                        return 0; // decoding might fail, in which case return zero samples
                    }
                }
            }

            case AudioFileFormat.flac:
            {
                version(decodeFLAC)
                {
                    assert(_flacDecoder !is null);

                    int* integerData = cast(int*)outData;
                    int samples = cast(int) drflac_read_s32(_flacDecoder, frames, integerData);

                    // "Samples are always output as interleaved signed 32-bit PCM."
                    // Convert to float with type-punning. Note that this looses some precision.
                    double factor = 1.0 / int.max;
                    foreach(n; 0..samples)
                    {
                        outData[n] = integerData[n]  * factor;
                    }  
                    return samples / _numChannels;
                }
                else
                {
                    assert(false); // Impossible
                }
            }
            
            case AudioFileFormat.ogg:
            {
                version(decodeOGG)
                {
                    assert(_oggDecoder !is null);
                    return _oggDecoder.stb_vorbis_get_samples_float_interleaved(_numChannels, outData, frames * _numChannels);
                }
                else
                {
                    assert(false); // Impossible
                }
            }

            case AudioFileFormat.mp3:
            {
                version(decodeMP3)
                {
                    assert(_mp3DecoderNew !is null);

                    int samplesNeeded = frames * _numChannels;
                    int result = cast(int) mp3dec_ex_read(_mp3DecoderNew, outData, samplesNeeded);
                    if (result < 0) // error
                        return 0;
                    return result / _numChannels;
                }
                else
                {
                    assert(false); // Impossible
                }
            }
            case AudioFileFormat.wav:
                version(decodeWAV)
                {
                    assert(_wavDecoder !is null);
                    int readFrames = _wavDecoder.readSamples(outData, frames); 
                    return readFrames;
                }
                else
                {
                    assert(false); // Impossible
                }

            case AudioFileFormat.xm:
                version(decodeXM)
                {
                    assert(_xmDecoder !is null);

                    if (xm_get_loop_count(_xmDecoder) >= 1)
                        return 0; // song is finished

                    xm_generate_samples(_xmDecoder, outData, frames);
                    return frames; // Note: XM decoder pads end with zeroes.
                }
                else
                {
                    assert(false); // Impossible
                }

            case AudioFileFormat.mod:
                version(decodeMOD)
                {
                    if (pocketmod_loop_count(_modDecoder) >= 1)
                        return 0; // end stream after MOD finishes, looping not supported
                    assert(_modDecoder !is null);
                    int bytesReturned = pocketmod_render(_modDecoder, outData, frames * 2 * 4);
                    assert((bytesReturned % 8) == 0);
                    return bytesReturned / 8;
                }
                else
                {
                    assert(false); // Impossible
                }

            case AudioFileFormat.unknown:
                // One shouldn't ever get there, since in this case
                // opening has failed.
                assert(false);
        }
    }
    ///ditto
    int readSamplesFloat(float[] outData) @nogc
    {
        assert( (outData.length % _numChannels) == 0);
        return readSamplesFloat(outData.ptr, cast(int)(outData.length / _numChannels) );
    }

    /// Write interleaved float samples to the stream, from the given buffer `inData[0..frames]`.
    /// 
    /// Params:
    ///     inData Buffer of interleaved samples to append to the stream.
    ///     frames The number of frames to append to the stream.
    ///
    /// Returns: Number of actually written frames. Multiply by `getNumChannels()` to get the number of written samples.
    ///          When that number is less than `frames`, it means the stream had a write error.
    int writeSamplesFloat(float* inData, int frames) nothrow @nogc
    {
        // If you fail here, you are using this `AudioStream` for encoding:
        // - after it has been destroyed,
        // - or after encoding has been finalized with 
        // - or it was created for encoding instead 
        assert(_io && _io.write !is null);

        final switch(_format)
        {
            case AudioFileFormat.mp3:
            case AudioFileFormat.flac:
            case AudioFileFormat.ogg:
            case AudioFileFormat.opus:
            case AudioFileFormat.mod:
            case AudioFileFormat.xm:
            case AudioFileFormat.unknown:
            {
                assert(false); // Shouldn't have arrived here, such encoding aren't supported.
            }
            case AudioFileFormat.wav:
            {
                version(encodeWAV)
                {
                    return _wavEncoder.writeSamples(inData, frames);
                }
                else
                {
                    assert(false, "no support for WAV encoding");
                }
            }
        }
    }
    ///ditto
    int writeSamplesFloat(float[] inData) nothrow @nogc
    {
        assert( (inData.length % _numChannels) == 0);
        return writeSamplesFloat(inData.ptr, cast(int)(inData.length / _numChannels));
    }

    /// Seeking. Subsequent reads start from multi-channel frame index `frames`.
    /// Only available for input streams.
    /// Formats that support seeking: WAV, MP3, OGG, FLAC.
    bool seekPosition(int frame)
    {
        assert(_io && (_io.read !is null) );
        final switch(_format) with (AudioFileFormat)
        {
            case mp3: 
                version(decodeMP3)
                    return (mp3dec_ex_seek(_mp3DecoderNew, frame * _numChannels) == 0);
                else
                    assert(false);
            case flac:
                version(decodeFLAC)
                    return drflac__seek_to_sample__brute_force (_flacDecoder, frame * _numChannels);
                else
                    assert(false);
            case ogg:
                version(decodeOGG)
                {
                    assert(false); // TODO: see #6
                }
                else 
                    assert(false);
            case opus:
                version(decodeOPUS)
                {
                    // Note: drflac seeks 1sec too early for some reason.
                    // This isn't sample accurate, rather 64ms accurate.
                    long timeInMs = 1000 + cast(long)(  1000.0 * frame / _sampleRate);
                    _opusDecoder.seek(timeInMs);
                    return true;
                }
                else 
                    assert(false);
            case mod:
            case xm:
                return false; // NOT IMPLEMENTED
            case wav:
                version(decodeWAV)
                    return _wavDecoder.seekPosition(frame);
                else
                    assert(false);
            case unknown:
                assert(false);

        }
    }

    /// Call `fflush()` on written samples, if any. 
    /// It is only useful for streamable output formats, that may want to flush things to disk.
    void flush() nothrow @nogc
    {
        assert( _io && (_io.write !is null) );
        _io.flush(userData);
    }
    
    /// Finalize encoding. After finalization, further writes are not possible anymore
    /// however the stream is considered complete and valid for storage.
    void finalizeEncoding() @nogc 
    {
        // If you crash here, it's because `finalizeEncoding` has been called twice.
        assert( _io && (_io.write !is null) );

        final switch(_format) with (AudioFileFormat)
        {
            case mp3:
            case flac:
            case ogg:
            case opus:
            case mod:
            case xm:
                assert(false); // unsupported output encoding
            case wav:
                { 
                    _wavEncoder.finalizeEncoding();
                    break;
                }
            case unknown:
                assert(false);
        }
        _io.write = null; // prevents further encodings
    }

    // Finalize encoding and get internal buffer.
    // This can be called multiple times, in which cases the stream is finalized only the first time.
    const(ubyte)[] finalizeAndGetEncodedResult() @nogc
    {
        // only callable while appending, else it's a programming error
        assert( (memoryContext !is null) && ( memoryContext.bufferCanGrow ) );

        finalizeEncodingIfNeeded(); 
        return memoryContext.buffer[0..memoryContext.size];
    }

private:
    IOCallbacks* _io;

    // This type of context is a closure to remember where the data is.
    void* userData; // is equal to either fileContext or memoryContext
    FileContext* fileContext;
    MemoryContext* memoryContext;

    // This type of context is a closure to remember where _io and user Data is.
    DecoderContext* _decoderContext;

    AudioFileFormat _format;
    float _sampleRate; 
    int _numChannels;
    long _lengthInFrames;

    // Decoders
    version(decodeMP3)
    {
        mp3dec_ex_t* _mp3DecoderNew; // allocated on heap since it's a 16kb object
        mp3dec_io_t* _mp3io;
    }
    version(decodeFLAC)
    {
        drflac* _flacDecoder;
    }
    version(decodeOGG)
    {
        ubyte[] _oggBuffer; // all allocations from the ogg decoder
        VorbisDecoder _oggDecoder;
    }
    version(decodeWAV)
    {
        WAVDecoder _wavDecoder;
    }
    version(decodeMOD)
    {
        pocketmod_context* _modDecoder = null;
        ubyte[] _modContent = null; // whole buffer, copied
    }
    version(decodeXM)
    {
        xm_context_t* _xmDecoder = null;
        ubyte* _xmContent = null;
    }

    version(decodeOPUS)
    {
        OpusFile _opusDecoder;
        short[] _opusBuffer;
    }

    // Encoder
    version(encodeWAV)
    {
        WAVEncoder _wavEncoder;
    }

    bool isOpenedForWriting() nothrow @nogc
    {
        // Note: 
        //  * when opened for reading, I/O operations given are: seek/tell/getFileLength/read.
        //  * when opened for writing, I/O operations given are: seek/tell/write/flush.
        return (_io !is null) && (_io.read is null);
    }

    void startDecoding() @nogc
    {
        // Create a decoder context
        _decoderContext = mallocNew!DecoderContext;
        _decoderContext.userDataIO = userData;
        _decoderContext.callbacks = _io;

        version(decodeOPUS)
        {
            try
            {
                _opusDecoder = opusOpen(_io, userData);
                assert(_opusDecoder !is null);
                _format = AudioFileFormat.opus;
                _sampleRate = _opusDecoder.rate; // Note: Opus file are always 48Khz
                _numChannels = _opusDecoder.channels();
                _lengthInFrames = _opusDecoder.smpduration();
                return;
            }
            catch(Exception e)
            {
                destroyFree(e);
            }
            _opusDecoder = null;
        }

        version(decodeFLAC)
        {
            _io.seek(0, false, userData);
            
            // Is it a FLAC?
            {
                drflac_read_proc onRead = &flac_read;
                drflac_seek_proc onSeek = &flac_seek;
                void* pUserData = _decoderContext;
                _flacDecoder = drflac_open (onRead, onSeek, _decoderContext);
                if (_flacDecoder !is null)
                {
                    _format = AudioFileFormat.flac;
                    _sampleRate = _flacDecoder.sampleRate;
                    _numChannels = _flacDecoder.channels;
                    _lengthInFrames = _flacDecoder.totalSampleCount / _numChannels;
                    return;
                }
            }
        }

        version(decodeWAV)
        {
            // Check if it's a WAV.

            _io.seek(0, false, userData);

            try
            {
                _wavDecoder = mallocNew!WAVDecoder(_io, userData);
                _wavDecoder.scan();

                // WAV detected
                _format = AudioFileFormat.wav;
                _sampleRate = _wavDecoder._sampleRate;
                _numChannels = _wavDecoder._channels;
                _lengthInFrames = _wavDecoder._lengthInFrames;
                return;
            }
            catch(Exception e)
            {
                // not a WAV
                destroyFree(e);
            }
            destroyFree(_wavDecoder);
            _wavDecoder = null;
        }

        version(decodeOGG)
        {
            _io.seek(0, false, userData);
            
            // Is it an OGG?
            {
                //"In my test files the maximal-size usage is ~150KB", so let's take a bit more
                _oggBuffer.reallocBuffer(200 * 1024);

                stb_vorbis_alloc alloc;
                alloc.alloc_buffer = cast(ubyte*)(_oggBuffer.ptr);
                alloc.alloc_buffer_length_in_bytes = cast(int)(_oggBuffer.length);

                int error;
                _oggDecoder = mallocNew!VorbisDecoder(_io, userData);
                if (_oggDecoder.error == STBVorbisError.no_error)
                {
                    _format = AudioFileFormat.ogg;
                    _sampleRate = _oggDecoder.sampleRate;
                    _numChannels = _oggDecoder.chans;
                    _lengthInFrames = _oggDecoder.streamLengthInSamples();
                    return;
                }
                else
                {
                    destroyFree(_oggDecoder);
                    _oggDecoder = null;
                }

            }
        }

        version(decodeMP3)
        {
            // Check if it's a MP3.
            {
                _io.seek(0, false, userData);

                ubyte* scratchBuffer = cast(ubyte*) malloc(MINIMP3_BUF_SIZE*2);
                scope(exit) free(scratchBuffer);

                _mp3io = cast(mp3dec_io_t*) malloc(mp3dec_io_t.sizeof);
                _mp3io.read      = &mp3_io_read;
                _mp3io.read_data = _decoderContext;
                _mp3io.seek      = &mp3_io_seek;
                _mp3io.seek_data = _decoderContext;

                if ( mp3dec_detect_cb(_mp3io, scratchBuffer, MINIMP3_BUF_SIZE*2) == 0 )
                {
                    // This is a MP3. Try to open a stream.

                    // Allocate a mp3dec_ex_t object
                    _mp3DecoderNew = cast(mp3dec_ex_t*) malloc(mp3dec_ex_t.sizeof);

                    int result = mp3dec_ex_open_cb(_mp3DecoderNew, _mp3io, MP3D_SEEK_TO_SAMPLE);

                    if (0 == result)
                    {
                        // MP3 detected
                        // but it seems we need to iterate all frames to know the length...
                        _format = AudioFileFormat.mp3;
                        _sampleRate = _mp3DecoderNew.info.hz;
                        _numChannels = _mp3DecoderNew.info.channels;
                        _lengthInFrames = _mp3DecoderNew.samples / _numChannels;
                        return;
                    }
                    else
                    {
                        free(_mp3DecoderNew);
                        _mp3DecoderNew = null;
                        free(_mp3io);
                        _mp3io = null;
                    }
                }
            }
        }

        version(decodeXM)
        {
            {
                // we need the first 60 bytes to check if XM
                char[60] xmHeader;
                int bytes;

                _io.seek(0, false, userData);
                long lenBytes = _io.getFileLength(userData);
                if (lenBytes < 60) 
                    goto not_a_xm;

                bytes = _io.read(xmHeader.ptr, 60, userData);
                if (bytes != 60)
                    goto not_a_xm;

               if (0 != xm_check_sanity_preload(xmHeader.ptr, 60))
                   goto not_a_xm;

                _xmContent = cast(ubyte*) malloc(cast(int)lenBytes);
                _io.seek(0, false, userData);
                bytes = _io.read(_xmContent, cast(int)lenBytes, userData);
                if (bytes != cast(int)lenBytes)
                    goto not_a_xm;

                if (0 == xm_create_context_safe(&_xmDecoder, cast(const(char)*)_xmContent, cast(size_t)lenBytes, 44100))
                {
                    assert(_xmDecoder !is null);

                    xm_set_max_loop_count(_xmDecoder, 1);

                    _format = AudioFileFormat.xm;
                    _sampleRate = 44100.0f;
                    _numChannels = 2;
                    _lengthInFrames = audiostreamUnknownLength;
                    return;
                }

                not_a_xm:
                assert(_xmDecoder == null);
                free(_xmContent);
                _xmContent = null;
            }
        } 

        version(decodeMOD)
        {
            {
                // we need either the first 1084 or 600 bytes if available
                _io.seek(0, false, userData);
                long lenBytes = _io.getFileLength(userData);
                if (lenBytes >= 600)
                {
                    int headerBytes = lenBytes > 1084 ? 1084 : cast(int)lenBytes;

                    ubyte[1084] header;
                    int bytes = _io.read(header.ptr, headerBytes, userData);

                    if (_pocketmod_ident(null, header.ptr, bytes))
                    {
                        // This is a MOD, allocate a proper context, and read the whole file.
                        _modDecoder = cast(pocketmod_context*) malloc(pocketmod_context.sizeof);

                        // Read whole .mod in a buffer, since the decoder work all from memory
                        _io.seek(0, false, userData);
                        _modContent.reallocBuffer(cast(size_t)lenBytes);
                        bytes = _io.read(_modContent.ptr, cast(int)lenBytes, userData);

                        if (pocketmod_init(_modDecoder, _modContent.ptr, bytes, 44100))
                        {
                            _format = AudioFileFormat.mod;
                            _sampleRate = 44100.0f;
                            _numChannels = 2;
                            _lengthInFrames = audiostreamUnknownLength;
                            return;
                        }
                    }
                }
            }
        }

        _format = AudioFileFormat.unknown;
        _sampleRate = float.nan;
        _numChannels = 0;
        _lengthInFrames = -1;

        throw mallocNew!Exception("Cannot decode stream: unrecognized encoding.");
    }

    void startEncoding(AudioFileFormat format, float sampleRate, int numChannels) @nogc
    { 
        _format = format;
        _sampleRate = sampleRate;
        _numChannels = numChannels;

        final switch(format) with (AudioFileFormat)
        {
            case mp3:
                throw mallocNew!Exception("Unsupported encoding format: MP3");
            case flac:
                throw mallocNew!Exception("Unsupported encoding format: FLAC");
            case ogg:
                throw mallocNew!Exception("Unsupported encoding format: OGG");
            case opus:
                throw mallocNew!Exception("Unsupported encoding format: Opus");
            case mod:
                throw mallocNew!Exception("Unsupported encoding format: MOD");
            case xm:
                throw mallocNew!Exception("Unsupported encoding format: XM");
            case wav:
            {
                // Note: fractional sample rates not supported by WAV, signal an integer one
                int isampleRate = cast(int)(sampleRate + 0.5f);
                _wavEncoder = mallocNew!WAVEncoder(_io, userData, isampleRate, numChannels );
                break;
            }
            case unknown:
                throw mallocNew!Exception("Can't encode using 'unknown' coding");
        }        
    }   

    void finalizeEncodingIfNeeded() @nogc
    {
        if (_io && (_io.write !is null)) // if we have been encoding something
        {
            finalizeEncoding();
        }
    }
}

// AudioStream should be able to go on a smallish 32-bit stack,
// and malloc the rest on the heap when needed.
static assert(AudioStream.sizeof <= 256); 

private: // not meant to be imported at all



// Internal object for audio-formats


// File callbacks
// The file callbacks are using the C stdlib.

struct FileContext // this is what is passed to I/O when used in file mode
{
    // Used when streaming of writing a file
    FILE* file = null;

    // Size of the file in bytes, only used when reading/writing a file.
    long fileSize;

    // Initialize this context
    void initialize(const(char)[] path, bool forWrite) @nogc
    {
        CString strZ = CString(path);
        file = fopen(strZ.storage, forWrite ? "wb".ptr : "rb".ptr);
        // finds the size of the file
        fseek(file, 0, SEEK_END);
        fileSize = ftell(file);
        fseek(file, 0, SEEK_SET);
    }
}

long file_tell(void* userData) nothrow @nogc
{
    FileContext* context = cast(FileContext*)userData;
    return ftell(context.file);
}

bool file_seek(long offset, bool relative, void* userData) nothrow @nogc
{
    FileContext* context = cast(FileContext*)userData;
    assert(offset <= int.max);
    int r = fseek(context.file, cast(int)offset, relative ? SEEK_CUR : SEEK_SET); // Limitations: file larger than 2gb not supported
    return r == 0;
}

long file_getFileLength(void* userData) nothrow @nogc
{
    FileContext* context = cast(FileContext*)userData;
    return context.fileSize;
}

int file_read(void* outData, int bytes, void* userData) nothrow @nogc
{
    FileContext* context = cast(FileContext*)userData;
    size_t bytesRead = fread(outData, 1, bytes, context.file);
    return cast(int)bytesRead;
}

int file_write(void* inData, int bytes, void* userData) nothrow @nogc
{
    FileContext* context = cast(FileContext*)userData;
    size_t bytesWritten = fwrite(inData, 1, bytes, context.file);
    return cast(int)bytesWritten;
}

bool file_skip(int bytes, void* userData) nothrow @nogc
{
    FileContext* context = cast(FileContext*)userData;
    return (0 == fseek(context.file, bytes, SEEK_CUR));
}

bool file_flush(void* userData) nothrow @nogc
{
    FileContext* context = cast(FileContext*)userData;
    return ( fflush(context.file) == 0 );
}

// Memory read callback
// Using the read buffer instead

struct MemoryContext
{
    bool bufferIsOwned;
    bool bufferCanGrow;

    // Buffer
    ubyte* buffer = null;

    size_t size;     // current buffer size
    size_t cursor;   // where we are in the buffer
    size_t capacity; // max buffer size before realloc

    void initializeWithConstantInput(const(ubyte)* data, size_t length) nothrow @nogc
    {
        // Make a copy of the input buffer, since it could be temporary.
        bufferIsOwned = true;
        bufferCanGrow = false;

        buffer = mallocDup(data[0..length]).ptr; // Note: the copied slice is made mutable.
        size = length;
        cursor = 0;
        capacity = length;
    }

    void initializeWithExternalOutputBuffer(ubyte* data, size_t length) nothrow @nogc
    {
        bufferIsOwned = false;
        bufferCanGrow = false;
        buffer = data;
        size = 0;
        cursor = 0;
        capacity = length;
    }

    void initializeWithInternalGrowableBuffer() nothrow @nogc
    {
        bufferIsOwned = true;
        bufferCanGrow = true;
        buffer = null;
        size = 0;
        cursor = 0;
        capacity = 0;
    }

    ~this()
    {
        if (bufferIsOwned)
        {
            if (buffer !is null)
            {
                free(buffer);
                buffer = null;
            }
        }
    }
}

long memory_tell(void* userData) nothrow @nogc
{
    MemoryContext* context = cast(MemoryContext*)userData;
    return cast(long)(context.cursor);
}

bool memory_seek(long offset, bool relative, void* userData) nothrow @nogc
{
    MemoryContext* context = cast(MemoryContext*)userData;    
    if (relative) offset += context.cursor;
    if (offset < 0)
        return false;

    bool r = true;
    if (offset >= context.size) // can't seek past end of buffer, stick to the end so that read return 0 byte
    {
        offset = context.size;
        r = false;
    }
    context.cursor = cast(size_t)offset; // Note: memory streams larger than 2gb not supported
    return r;
}

long memory_getFileLength(void* userData) nothrow @nogc
{
    MemoryContext* context = cast(MemoryContext*)userData;
    return cast(long)(context.size);
}

int memory_read(void* outData, int bytes, void* userData) nothrow @nogc
{
    MemoryContext* context = cast(MemoryContext*)userData;
    size_t cursor = context.cursor;
    size_t size = context.size;
    size_t available = size - cursor;
    if (bytes < available)
    {
        outData[0..bytes] = context.buffer[cursor..cursor + bytes];
        context.cursor += bytes;
        return bytes;
    }
    else
    {
        outData[0..available] = context.buffer[cursor..cursor + available];
        context.cursor = context.size;
        return cast(int)available;
    }
}

int memory_write_limited(void* inData, int bytes, void* userData) nothrow @nogc
{
    MemoryContext* context = cast(MemoryContext*)userData;
    size_t cursor = context.cursor;
    size_t size = context.size;
    size_t available = size - cursor;
    ubyte* buffer = context.buffer;
    ubyte* source = cast(ubyte*) inData;

    if (cursor + bytes > available)
    {
        bytes = cast(int)(available - cursor);       
    }

    buffer[cursor..(cursor + bytes)] = source[0..bytes];
    context.size += bytes;
    context.cursor += bytes;
    return bytes;
}

int memory_write_append(void* inData, int bytes, void* userData) nothrow @nogc
{
    MemoryContext* context = cast(MemoryContext*)userData;
    size_t cursor = context.cursor;
    size_t size = context.size;
    size_t available = size - cursor;
    ubyte* buffer = context.buffer;
    ubyte* source = cast(ubyte*) inData;

    if (cursor + bytes > available)
    {
        size_t oldSize = context.capacity;
        size_t newSize = cursor + bytes;
        if (newSize < oldSize * 2 + 1) 
            newSize = oldSize * 2 + 1;
        buffer = cast(ubyte*) realloc(buffer, newSize);
        context.capacity = newSize;

        assert( cursor + bytes <= available );
    }

    buffer[cursor..(cursor + bytes)] = source[0..bytes];
    context.size += bytes;
    context.cursor += bytes;
    return bytes;
}

bool memory_skip(int bytes, void* userData) nothrow @nogc
{
    MemoryContext* context = cast(MemoryContext*)userData;
    context.cursor += bytes;
    return context.cursor <= context.size;
}

bool memory_flush(void* userData) nothrow @nogc
{
    // do nothing, no flushign to do for memory
    return true;
}


// Decoder context
struct DecoderContext
{
    void* userDataIO;
    IOCallbacks* callbacks;
}

// MP3 decoder read callback
static int mp3ReadDelegate(void[] buf, void* userDataDecoder) @nogc nothrow
{
    DecoderContext* context = cast(DecoderContext*) userDataDecoder;

    // read bytes into the buffer, return number of bytes read or 0 for EOF, -1 on error
    // will never be called with empty buffer, or buffer more than 128KB

    int bytes = context.callbacks.read(buf.ptr, cast(int)(buf.length), context.userDataIO);
    return bytes;
}


// FLAC decoder read callbacks

size_t flac_read(void* pUserData, void* pBufferOut, size_t bytesToRead) @nogc nothrow
{
    DecoderContext* context = cast(DecoderContext*) pUserData;
    return context.callbacks.read(pBufferOut, cast(int)(bytesToRead), context.userDataIO);
}

bool flac_seek(void* pUserData, int offset, drflac_seek_origin origin) @nogc nothrow
{
    DecoderContext* context = cast(DecoderContext*) pUserData;
    if (origin == drflac_seek_origin_start)
    {
        context.callbacks.seek(offset, false, context.userDataIO);
    }
    else if (origin == drflac_seek_origin_current)
    {
        context.callbacks.seek(offset, true, context.userDataIO);
    }
    return true;
}

// MP3 decoder read callbacks

size_t mp3_io_read(void *buf, size_t size, void *user_data) @nogc nothrow
{
    DecoderContext* context = cast(DecoderContext*) user_data;
    return context.callbacks.read(buf, cast(int)(size), context.userDataIO);
}

int mp3_io_seek(ulong position, void *user_data) @nogc nothrow
{
    DecoderContext* context = cast(DecoderContext*) user_data;
    context.callbacks.seek(position, false, context.userDataIO);
    return 0; // doesn't detect seeking errors
}