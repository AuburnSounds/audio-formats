module audioformats.io;

import dplug.core.nogc;


nothrow @nogc
{
    alias ioSeekCallback          = void function(long offset, bool relative, void* userData);
    alias ioTellCallback          = long function(                            void* userData);  
    alias ioGetFileLengthCallback = long function(                            void* userData);
    alias ioReadCallback          = int  function(void* outData, int bytes,   void* userData); // returns number of read bytes
    alias ioWriteCallback         = int  function(void* inData, int bytes,    void* userData); // returns number of written bytes
    alias ioSkipCallback          = bool function(int bytes,                  void* userData);
    alias ioFlushCallback         = bool function(                            void* userData);
}

struct IOCallbacks
{
    ioSeekCallback seek;
    ioTellCallback tell;
    ioGetFileLengthCallback getFileLength;
    ioReadCallback read;
    ioWriteCallback write;
    ioSkipCallback skip;
    ioFlushCallback flush;


    // Now, some helpers for binary parsing based on these callbacks

    // <reading>

    bool nothingToReadAnymore(void* userData) @nogc
    {
        return remainingBytesToRead(userData) <= 0;
    }

    long remainingBytesToRead(void* userData) @nogc
    {
        long cursor = tell(userData);
        long fileLength = getFileLength(userData);
        assert(cursor <= fileLength);
        return fileLength - cursor;
    }
  
    ubyte peek_ubyte(void* userData) @nogc
    {
        ubyte b = read_ubyte(userData);
        seek(tell(userData) - 1, false, userData);
        return b;
    }

    ubyte read_ubyte(void* userData) @nogc
    {
        ubyte b;
        if (1 == read(&b, 1, userData))
        {
            return b;
        }
        throw mallocNew!Exception("expected ubyte");
    }

    ushort read_ushort_LE(void* userData) @nogc
    {
        ubyte[2] v;
        if (2 == read(v.ptr, 2, userData))
        {
            version(BigEndian)
            {
                ubyte v0 = v[0];
                v[0] = v[1];
                v[1] = v0;
            }
            return *cast(ushort*)(v.ptr);
        }
        else
            throw mallocNew!Exception("expected ushort");
    }

    uint read_uint_BE(void* userData) @nogc
    {
        ubyte[4] v;
        if (4 == read(v.ptr, 4, userData))
        {
            version(LittleEndian)
            {
                ubyte v0 = v[0];
                v[0] = v[3];
                v[3] = v0;
                ubyte v1 = v[1];
                v[1] = v[2];
                v[2] = v1;
            }
            return *cast(uint*)(v.ptr);
        }
        else
            throw mallocNew!Exception("expected uint");
    }

    uint read_uint_LE(void* userData) @nogc
    {
        ubyte[4] v;
        if (4 == read(v.ptr, 4, userData))
        {
            version(BigEndian)
            {
                ubyte v0 = v[0];
                v[0] = v[3];
                v[3] = v0;
                ubyte v1 = v[1];
                v[1] = v[2];
                v[2] = v1;
            }
            return *cast(uint*)(v.ptr);
        }
        else
            throw mallocNew!Exception("expected uint");
    }

    uint read_24bits_LE(void* userData) @nogc
    {
        ubyte[3] v;
        if (3 == read(v.ptr, 3, userData))
        {
            return v[0] | (v[1] << 8) || (v[2] << 16);
        }
        else
            throw mallocNew!Exception("expected 24-bit int");
    }

    float read_float_LE(void* userData) @nogc
    {
        uint u = read_uint_LE(userData);
        return *cast(float*)(&u);
    }

    double read_double_LE(void* userData) @nogc
    {
        ubyte[8] v;
        if (8 == read(v.ptr, 8, userData))
        {
            version(BigEndian)
            {
                ubyte v0 = v[0];
                v[0] = v[7];
                v[7] = v0;
                ubyte v1 = v[1];
                v[1] = v[6];
                v[6] = v1;
                ubyte v2 = v[2];
                v[2] = v[5];
                v[5] = v2;
                ubyte v3 = v[3];
                v[3] = v[4];
                v[4] = v3;
            }
            return *cast(double*)(v.ptr);
        }
        else
            throw mallocNew!Exception("expected double");
    }

    void readRIFFChunkHeader(void* userData, ref uint chunkId, ref uint chunkSize) @nogc
    {
        chunkId = read_uint_BE(userData);
        chunkSize = read_uint_LE(userData);
    }

    // </reading>

    // <writing>

    string writeFailureMessage = "write failure";

    void write_uint_BE(void* userData, uint value) @nogc
    {
        ubyte[4] v;
        *cast(uint*)(v.ptr) = value;
        version(LittleEndian)
        {
            ubyte v0 = v[0];
            v[0] = v[3];
            v[3] = v0;
            ubyte v1 = v[1];
            v[1] = v[2];
            v[2] = v1;
        }

        if (4 != write(v.ptr, 4, userData))
            throw mallocNew!Exception(writeFailureMessage);
    }

    void write_float_LE(void* userData, float value) @nogc
    {
        write_uint_LE(userData, *cast(uint*)(&value));
    }

    void write_uint_LE(void* userData, uint value) @nogc
    {
        ubyte[4] v;
        *cast(uint*)(v.ptr) = value;
        version(BigEndian)
        {
            ubyte v0 = v[0];
            v[0] = v[3];
            v[3] = v0;
            ubyte v1 = v[1];
            v[1] = v[2];
            v[2] = v1;
        }

        if (4 != write(v.ptr, 4, userData))
            throw mallocNew!Exception(writeFailureMessage);
    }

    void write_ushort_LE(void* userData, uint value) @nogc
    {
        ubyte[2] v;
        *cast(uint*)(v.ptr) = value;
        version(BigEndian)
        {
            ubyte v0 = v[0];
            v[0] = v[1];
            v[1] = v0;
        }

        if (2 != write(v.ptr, 2, userData))
            throw mallocNew!Exception(writeFailureMessage);
    }

    void writeRIFFChunkHeader(void* userData, uint chunkId, uint chunkSize) @nogc
    {
        write_uint_BE(userData, chunkId);
        write_uint_LE(userData, chunkSize);
    }

    // </writing>
}


template RIFFChunkId(string id)
{
    static assert(id.length == 4);
    uint RIFFChunkId = (cast(ubyte)(id[0]) << 24)
        | (cast(ubyte)(id[1]) << 16)
        | (cast(ubyte)(id[2]) << 8)
        | (cast(ubyte)(id[3]));
}
