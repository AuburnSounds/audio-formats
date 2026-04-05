module main;

import audioformats;
import core.stdc.stdlib;
import core.stdc.stdio;

//debug = checkSeeking;

int main(string[] args)
{   
    if (args.length != 3)
    {
        printf("usage: transcode input.{mp3|wav|flac|ogg|opus|qoa|mod|xm} output.{wav|qoa}\n");
        return 1;
    }

    string inputPath = args[1];
    string outputPath = args[2];

    AudioStream input, output;

    input.openFromFile(args[1]);

    float sampleRate = input.getSamplerate();
    int channels = input.getNumChannels();
    long lengthFrames = input.getLengthInFrames();

    printf("Opening %.*s\n", cast(int)inputPath.length, inputPath.ptr);
    printf("  * format     = %d\n", input.getFormat() );
    printf("  * samplerate = %f Hz\n", sampleRate);
    printf("  * channels   = %d\n", channels);
    if (lengthFrames == audiostreamUnknownLength)
    {
        printf("  * length     = unknown\n");
    }
    else
    {
        double seconds = lengthFrames / cast(double) sampleRate;
        printf("  * length     = %.3g seconds (%lld frames)\n", seconds, lengthFrames);
    }

    debug(checkSeeking) additionalTests(input);

    float[] buf = new float[1024 * channels];

    EncodingOptions options;
    options.sampleFormat = AudioSampleFormat.s24;
    options.enableDither = true;

    options.flacQuality = 5; // 0 to 12

    bool isFLAC = outputPath.length > 5 && outputPath[$-5..$] == ".flac";
    bool isQOA = outputPath.length > 4 && outputPath[$-4..$] == ".qoa";
    AudioFileFormat outFormat = AudioFileFormat.wav;
    if (isQOA) outFormat = AudioFileFormat.qoa;
    if (isFLAC) outFormat = AudioFileFormat.flac;
    
    output.openToFile(outputPath, outFormat, sampleRate, channels, options);
    if (output.isError)
    {
        const(char)[] err = output.errorMessage;
        printf("error: %.*s\n", cast(int) err.length, err.ptr);
    }

    // Chunked encode/decode
    int totalFrames = 0;
    int framesRead;
    do
    {
        framesRead = input.readSamplesFloat(buf);
        if (input.isError)
        {
            const(char)[] err = input.errorMessage;
            printf("error: %.*s\n", cast(int) err.length, err.ptr);
        }
        output.writeSamplesFloat(buf[0..framesRead*channels]);
        if (output.isError)
        {
            const(char)[] err = output.errorMessage;
            printf("error: %.*s\n", cast(int) err.length, err.ptr);
        }
        totalFrames += framesRead;
    } while(framesRead > 0);

    // Always call this for output, else the stream might be incomplete or non-working!
    if (!output.finalizeEncoding())
    {
        const(char)[] err = output.errorMessage;
        printf("error while encoding: %.*s\n", cast(int) err.length, err.ptr);
    }

    // Note: if you need bytes on the disk right now, call output.flush()
    // .finalizeEncoding call all the fwrite needed for footer and complete signal,
    // while .flush call .fflush

    printf("=> %d frames decoded and encoded to %.*s\n", totalFrames, cast(int)outputPath.length, outputPath.ptr);
    return 0;
}

debug(checkSeeking)
{
    // For audio-formats debug purpose.
    void additionalTests(ref AudioStream input)
    {
        int channels = input.getNumChannels();
        long lengthFrames = input.getLengthInFrames();
        if (lengthFrames == audiostreamUnknownLength)
            return;

        int maxFrame = cast(int) lengthFrames;

        // Check that seeking work
        if (input.canSeek() && !input.isModule())
        {
            assert(input.tellPosition() == 0);

            // Seeking at beginning is always legal.
            bool res = input.seekPosition(0);
            assert(res && input.tellPosition() == 0);

            // Seeking past the end is illegal and is a no-op
            res = input.seekPosition(maxFrame + 1);
            assert(!res && input.tellPosition() == 0);

            // Seeking before beginning is illegal and is a no-op
            res = input.seekPosition(-1);
            assert(!res && input.tellPosition() == 0);

            // Seeking in the middle is of course legal
            {
                int where = maxFrame / 2;
                res = input.seekPosition(where);
                int here = input.tellPosition();
                assert(res && here == where);
            }

            // It is legal to seek just before the end.
            if (maxFrame > 0)
            {
                res = input.seekPosition(maxFrame - 1);
                int pos = input.tellPosition();
                assert(res && pos == maxFrame - 1);

                AudioFileFormat fmt = input.getFormat();
                {
                    // Where the remaining decoding should yield one frame
                    float[] smallbuf = new float[16 * channels];
                    int read = input.readSamplesFloat(smallbuf);
                    assert(read == 1);

                    res = input.seekPosition(maxFrame);
                    pos = input.tellPosition();
                    assert(res && pos == maxFrame);
                    // Where the remaining decoding should yield 0 frame
                    read = input.readSamplesFloat(smallbuf);
                    assert(read == 0);

                    // And at this point we cannot seek to beginning in OGG, since stream is finished (has returned 0 samples).
                }
            }

            // Come back at start, read 16 frames.
            res = input.seekPosition(0);
            assert(res && input.tellPosition() == 0);
            {
                float[] smallbuf = new float[16 * channels];
                int read = input.readSamplesFloat(smallbuf);
                assert(read == 16);
            }
            res = input.seekPosition(0);
        }
    }
}

