module main;

import std.stdio;
import std.file;

import audioformats;

// Currently it can take a MOD and dump patterns in the wrong order...
// Is or seek function conceptually correct?

void main(string[] args)
{
    if (args.length != 3)
        throw new Exception("usage: dump-patterns input.{mod|xm} doubled.wav");

    string inputPath = args[1];
    string outputPath = args[2];

    try
    {

        AudioStream input, output;

        input.openFromFile(args[1]);
        if (input.isError)
            throw new Exception(input.errorMessage);
        float sampleRate = input.getSamplerate();
        int channels = input.getNumChannels();
        long lengthFrames = input.getLengthInFrames();

        if (!input.isModule)
            throw new Exception("Must be a module");
        if (!input.canSeek)
            throw new Exception("Must be seekable");

        float[] buf;
        output.openToFile(outputPath, AudioFileFormat.wav, sampleRate, channels);
        if (output.isError)
            throw new Exception(output.errorMessage);


        int patternCount = input.getModuleLength();

        for (int pattern = 0; pattern < patternCount; ++pattern) // Note: that iterated patterns in order, but that's not the right order in the MOD
        {
            input.seekPosition(pattern, 0);

            // how many remaining frames in this pattern?
            int remain = cast(int) input.framesRemainingInPattern();
            buf.length = remain * channels;
            int framesRead = input.readSamplesFloat(buf); // this should read the whole pattern
            if (input.isError)
                throw new Exception(input.errorMessage);
            assert( (framesRead == remain) );

            output.writeSamplesFloat(buf[0..framesRead*channels]);
            if (output.isError)
                throw new Exception(output.errorMessage);
        }

        output.destroy();
        
        writefln("=> %s patterns decoded and encoded to %s", patternCount, outputPath);
    }
    catch(Exception e)
    {
        writeln(e.msg);
    }
}