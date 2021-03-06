/*
 *  zlib License
 *  
 *  (C) 2016 jython234
 *  
 *  This software is provided 'as-is', without any express or implied
 *  warranty.  In no event will the authors be held liable for any damages
 *  arising from the use of this software.
 *  
 *  Permission is granted to anyone to use this software for any purpose,
 *  including commercial applications, and to alter it and redistribute it
 *  freely, subject to the following restrictions:
 *  
 *  1. The origin of this software must not be misrepresented; you must not
 *     claim that you wrote the original software. If you use this software
 *     in a product, an acknowledgment in the product documentation would be
 *     appreciated but is not required.
 *  2. Altered source versions must be plainly marked as such, and must not be
 *     misrepresented as being the original software.
 *  3. This notice may not be removed or altered from any source distribution.
*/
module blocksound.backend.openal;

version(blocksound_ALBackend) {

    pragma(msg, "-----BlockSound using OpenAL backend-----");

    import blocksound.core;
    import blocksound.backend.types;

    import derelict.openal.al;
    import derelict.sndfile.sndfile;

    import std.concurrency;

    /// Class to manage the OpenAL Audio backend.
    class ALAudioBackend : AudioBackend {
        protected ALCdevice* device;
        protected ALCcontext* context;

        /// Create a new ALBackend. One per thread.
        this() @trusted {
            debug(blocksound_verbose) {
                import std.stdio : writeln;
                writeln("[BlockSound]: Initializing OpenAL backend...");
            }

            device = alcOpenDevice(null); // Open default device.
            context = alcCreateContext(device, null);

            alcMakeContextCurrent(context);

            debug(blocksound_verbose) {
                import std.stdio : writeln;
                writeln("[BlockSound]: OpenAL Backend initialized.");
                writeln("[BlockSound]: AL_VERSION: ", toDString(alGetString(AL_VERSION)), ", AL_VENDOR: ", toDString(alGetString(AL_VENDOR)));
            }
        }

        override {
            void setListenerLocation(in Vec3 loc) @trusted nothrow {
                alListener3f(AL_POSITION, loc.x, loc.y, loc.z);
            }

            void setListenerGain(in float gain) @trusted nothrow {
                alListenerf(AL_GAIN, gain);
            }

            void cleanup() @trusted nothrow {
                alcCloseDevice(device);
            }
        }
    }

    /// OpenAL Source backend
    class ALSource : Source {
        package ALuint source;

        package this() @trusted {
            alGenSources(1, &source);
        }

        override {
            protected void _setSound(Sound sound) @trusted {
                if(auto s = cast(ALSound) sound) {
                    alSourcei(source, AL_BUFFER, s.buffer);
                } else {
                    throw new Exception("Invalid Sound: not instance of ALSound");
                }
            }

            void setLooping(in bool loop) @trusted {
                alSourcei(source, AL_LOOPING, loop ? AL_TRUE : AL_FALSE);
            }
 
            void play() @trusted nothrow {
                alSourcePlay(source);
            }

            void pause() @trusted nothrow {
                alSourcePause(source);
            }

            void stop() @trusted nothrow {
                alSourceStop(source);
            }

            bool hasFinishedPlaying() @trusted nothrow {
                ALenum state;
                alGetSourcei(source, AL_SOURCE_STATE, &state);
                return state != AL_PLAYING;
            }

            protected void _cleanup() @system nothrow {
                alDeleteSources(1, &source);
            }
        }
    }

    /// OpenAL Source backend (for streaming.)
    class ALStreamingSource : StreamingSource {

        static immutable size_t
            STREAM_CMD_PLAY = 0,
            STREAM_CMD_PAUSE = 1,
            STREAM_CMD_STOP = 2,
            STREAM_CMD_SET_LOOP_TRUE = 3,
            STREAM_CMD_SET_LOOP_FALSE = 4,
            STREAM_IS_PLAYING = 5,
            STREAM_STATE_PLAYING = 6,
            STREAM_STATE_STOPPED = 7;

        package ALuint source;

        private Tid streamThread;
        private ALStreamedSound sound;

        package shared finishedPlaying = false;

        package this() @trusted {
            alGenSources(1, &source);
        }

        override {
            protected void _setSound(Sound sound) @trusted {
                if(!(this.sound is null)) throw new Exception("Sound already set!");

                if(auto s = cast(ALStreamedSound) sound) {
                    this.sound = s;

                    alSourceQueueBuffers(source, s.numBuffers, s.buffers.ptr);
                    streamThread = spawn(&streamSoundThread, cast(shared) this, cast(shared) this.sound);
                } else {
                    throw new Exception("Invalid Sound: not instance of ALStreamedSound");
                }
            }

            void setLooping(in bool loop) @trusted {
                //alSourcei(source, AL_LOOPING, loop ? AL_TRUE : AL_FALSE);
                streamThread.send(loop ? STREAM_CMD_SET_LOOP_TRUE : STREAM_CMD_SET_LOOP_FALSE);
            }
 
            void play() @trusted {
                alSourcePlay(source);
                streamThread.send(STREAM_CMD_PLAY);
            }

            void pause() @trusted {
                alSourcePause(source);
                streamThread.send(STREAM_CMD_PAUSE);
            }

            void stop() @trusted {
                alSourceStop(source);
                streamThread.send(STREAM_CMD_STOP);
            }

            bool hasFinishedPlaying() @trusted nothrow {
                /*
                ALenum state;
                alGetSourcei(source, AL_SOURCE_STATE, &state);
                return state != AL_PLAYING;*/
                return finishedPlaying;
            }

            protected void _cleanup() @system nothrow {
                alDeleteSources(1, &source);
            }
        }
    }   

    /// The dedicated sound streaming thread. This is used to refill buffers while streaming sound.
    package void streamSoundThread(shared ALStreamingSource source, shared ALStreamedSound sound) @system {
        import std.datetime;
        import core.thread : Thread;

        bool hasFinished = false;
        bool isPlaying = false;
        bool loop = false;

        //bool waitForLoop = false; // Wait for AL to go through all the buffers.

        debug(blocksound_verbose) {
            import std.stdio;
            writeln("[BlockSound]: Started dedicated streaming thread.");
        }
        
        while(true) {
            receiveTimeout(dur!("msecs")(1), // Check for messages from main thread.
                (immutable size_t signal) {
                    switch(signal) {
                        case ALStreamingSource.STREAM_CMD_PLAY:
                            isPlaying = true;
                            break;
                        case ALStreamingSource.STREAM_CMD_PAUSE:
                            isPlaying = false;
                            break;
                        case ALStreamingSource.STREAM_CMD_STOP:
                            isPlaying = false;
                            hasFinished = true;
                            break;

                        case ALStreamingSource.STREAM_CMD_SET_LOOP_TRUE:
                            loop = true;
                            break;
                        case ALStreamingSource.STREAM_CMD_SET_LOOP_FALSE:
                            loop = false;
                            break;
                        default:
                            break;
                    }
            });

isPlayingLabel:
            if(isPlaying) { // Check if we are supposed to be playing (refilling buffers)
                ALint state, processed;

                alGetSourcei(source.source, AL_SOURCE_STATE, &state); // Get the state of the audio.
                alGetSourcei(source.source, AL_BUFFERS_PROCESSED, &processed); // Get the amount of buffers that OpenAL has played.

                if(processed > 0) {
                    alSourceUnqueueBuffers(cast(ALuint) source.source, processed, (cast(ALuint[])sound.buffers).ptr); // Unqueue buffers that have been played.
                    debug(blocksound_verbose2) {
                        import std.stdio;
                        writeln("[BlockSound/DEBUG ", Clock.currTime().second, "]: STATE, ", state, " ", AL_PLAYING, " Unqueued ", processed, " buffers.");
                    }

                    alDeleteBuffers(processed, (cast(ALuint[])sound.buffers).ptr); // Delete the played buffers

                    for(size_t i = 0; i < processed; i++) { // Go through each buffer that was played.
                        try {
                            ALuint buffer = (cast(ALStreamedSound) sound).queueBuffer(); // load a new buffer
                            sound.buffers[i] = buffer; // Add it to the array
                        } catch(EOFException e) { // Check if we have finished reading the sound file
                            if(loop) { // Check if we are looping the sound.
                                debug(blocksound_verbose2) {
                                    import std.stdio;
                                    writeln("[BlockSound/DEBUG", Clock.currTime().second, "]: Resetting...");
                                }
                                //alSourceStop((cast(ALStreamingSource) source).source);
                                (cast(ALStreamedSound) sound).reset();

                                ALuint buffer = (cast(ALStreamedSound) sound).queueBuffer(); // load a new buffer
                                sound.buffers[i] = buffer; // Add it to the array

                                debug(blocksound_verbose) {
                                    import std.stdio;
                                    writeln("[BlockSound ", Clock.currTime().second, "]: Dedicated streaming thread reset.");
                                }
                                break;
                            } else { // We are done here, time to close up shop.
                                hasFinished = true;
                                source.finishedPlaying = true; // Notify main thread that we are done.

                                debug(blocksound_verbose) {
                                    import std.stdio;
                                    writeln("[BlockSound ", Clock.currTime().second, "]: Dedicated streaming thread finished.");
                                }
                                break; // Break out of the loop, and exit the thread.
                            }
                        }
                    }

                    alSourceQueueBuffers(cast(ALuint) source.source, processed, (cast(ALuint[])sound.buffers).ptr); // Queue the new buffers to OpenAL.
                    debug(blocksound_verbose2) {
                        import std.stdio;
                        writeln("[BlockSound/DEBUG ", Clock.currTime().second, "]: Queued ", processed, " buffers.");
                    }
                }
                
                if(state != AL_PLAYING && !hasFinished) {
                    debug(blocksound_verbose2) {
                        import std.stdio;
                        writeln("[BlockSound/DEBUG ", Clock.currTime().second, "]: Set to play.");
                    }
                    alSourcePlay(source.source);
                }
                

                Thread.sleep(dur!("msecs")(5)); // Sleep 5 msecs as to prevent high CPU usage.
            }

            if(hasFinished) {
                source.finishedPlaying = true; // Notify main thread that we are done.
                break;
            }
        }

        debug(blocksound_verbose) {
            import std.stdio;
            writeln("[BlockSound]: Exiting dedicated streaming thread.");
        }
    }

    /// OpenAL Sound backend
    class ALSound : Sound {
        private ALuint _buffer;

        @property ALuint buffer() @safe nothrow { return _buffer; }

        protected this(ALuint buffer) @safe nothrow {
            _buffer = buffer;
        }

        static ALSound loadSound(in string filename) @trusted {
            return new ALSound(loadSoundToBuffer(filename));
        }

        override void cleanup() @trusted nothrow {
            alDeleteBuffers(1, &_buffer);
        }
    }

    /// OpenAL Sound backend (for streaming)
    class ALStreamedSound : StreamedSound {
        private string filename;
        private SF_INFO soundInfo;
        private SNDFILE* file;

        package ALuint numBuffers;
        package ALuint[] buffers;

        private this(in string filename, SF_INFO soundInfo, SNDFILE* file, ALuint numBuffers) @safe {
            this.filename = filename;
            this.soundInfo = soundInfo;
            this.file = file;
            this.numBuffers = numBuffers;

            buffers = new ALuint[numBuffers];
        }

        static ALStreamedSound loadSound(in string filename, in ALuint bufferNumber = 4) @system {
            import std.exception : enforce;
            import std.file : exists;

            enforce(INIT, new Exception("BlockSound has not been initialized!"));
            enforce(exists(filename), new Exception("File \"" ~ filename ~ "\" does not exist!"));

            SF_INFO info;
            SNDFILE* file;

            file = sf_open(toCString(filename), SFM_READ, &info);

            ALStreamedSound sound =  new ALStreamedSound(filename, info, file, bufferNumber);
            for(size_t i = 0; i < bufferNumber; i++) {
                ALuint buffer = sound.queueBuffer();
                sound.buffers[i] = buffer;
            }

            return sound;
        }

        /// Reset the file to the beginning.
        package void reset() @system {
            import core.stdc.stdio : SEEK_SET;
            sf_seek(file, 0, SEEK_SET);
        }

        private ALuint queueBuffer() @system {
            ALuint buffer;
            alGenBuffers(1, &buffer);

            AudioBufferFloat ab = sndfile_readFloats(file, soundInfo, 48_000);
            alBufferData(buffer, soundInfo.channels == 1 ? AL_FORMAT_MONO_FLOAT32 : AL_FORMAT_STEREO_FLOAT32, ab.data.ptr, cast(int) (ab.data.length * float.sizeof), soundInfo.samplerate);
            return buffer;
        }

        override {
            void cleanup() @trusted {
                alDeleteBuffers(numBuffers, buffers.ptr);
                sf_close(file);
            }
        }
    }

    /++
        Read an amount of shorts from a sound file using libsndfile.
    +/
    deprecated("Reading as shorts can cause cracks in audio") 
    AudioBuffer sndfile_readShorts(SNDFILE* file, SF_INFO info, size_t frames) @system {
        AudioBuffer ab;

        ab.data = new short[frames * info.channels];

        if((ab.remaining = sf_read_short(file, ab.data.ptr, ab.data.length)) <= 0) {
            throw new EOFException("EOF!");
        } 

        return ab;
    }

    /++
        Read an amount of shorts from a sound file using libsndfile.
    +/
    AudioBufferFloat sndfile_readFloats(SNDFILE* file, SF_INFO info, size_t frames) @system {
        AudioBufferFloat ab;

        ab.data = new float[frames * info.channels];

        if((ab.remaining = sf_read_float(file, ab.data.ptr, ab.data.length)) <= 0) {
            throw new EOFException("EOF!");
        } 

        return ab;
    }

    
    deprecated("Reading as shorts can cause cracks in audio") 
    package struct AudioBuffer {
        short[] data;
        sf_count_t remaining;
    }

    package struct AudioBufferFloat {
        float[] data;
        sf_count_t remaining;
    }

    /++
        Loads a sound from a file into an OpenAL buffer.
        Uses libsndfile for file reading.

        Params:
                filename =  The filename where the sound is located.
        
        Throws: Exception if file is not found, or engine is not initialized.
        Returns: An OpenAL buffer containing the sound.
    +/
    ALuint loadSoundToBuffer(in string filename) @system {
        import std.exception : enforce;
        import std.file : exists;

        enforce(INIT, new Exception("BlockSound has not been initialized!"));
        enforce(exists(filename), new Exception("File \"" ~ filename ~ "\" does not exist!"));

        SF_INFO info;
        SNDFILE* file = sf_open(toCString(filename), SFM_READ, &info);

        float[] data;
        float[] readBuf = new float[2048];

        long readSize = 0;
        while((readSize = sf_read_float(file, readBuf.ptr, readBuf.length)) != 0) {
            data ~= readBuf[0..(cast(size_t) readSize)];
        }

        ALuint buffer;
        alGenBuffers(1, &buffer);
        debug(blocksound_soundInfo) {
            import std.stdio : writeln;
            writeln("Loading sound ", filename, ": has ", info.channels, " channels.");
        }
        alBufferData(buffer, info.channels == 1 ? AL_FORMAT_MONO_FLOAT32 : AL_FORMAT_STEREO_FLOAT32, data.ptr, cast(int) (data.length * float.sizeof), info.samplerate);

        sf_close(file);

        return buffer;
    }

    /++
        Loads libraries required by the OpenAL backend.
        This is called automatically by blocksound's init
        function.

        Params:
                skipALload =    Skips loading OpenAL from derelict.
                                Set this to true if your application loads
                                OpenAL itself before blocksound does.

                skipSFLoad =    Skips loading libsndfile from derelict.
                                Set this to true if your application loads
                                libsdnfile itself before blocksound does.
    +/
    void loadLibraries(bool skipALload = false, bool skipSFload = false) @system {
        if(!skipALload) {
            version(Windows) {
                try {
                    DerelictAL.load(); // Search for system libraries first.
                    debug(blocksound_verbose) notifyLoadLib("OpenAL");
                } catch(Exception e) {
                    DerelictAL.load("lib\\openal32.dll"); // Try to use provided library.
                    debug(blocksound_verbose) notifyLoadLib("OpenAL");
                }
            } else {
                DerelictAL.load();
                debug(blocksound_verbose) notifyLoadLib("OpenAL");
            }
        }

        if(!skipSFload) {
            version(Windows) {
                try {
                    DerelictSndFile.load(); // Search for system libraries first.
                    debug(blocksound_verbose) notifyLoadLib("libsndfile");
                } catch(Exception e) {
                    DerelictSndFile.load("lib\\libsndfile-1.dll"); // Try to use provided library.
                    debug(blocksound_verbose) notifyLoadLib("libsndfile");
                }
            } else {
                DerelictSndFile.load();
                debug(blocksound_verbose) notifyLoadLib("libsndfile");
            }
        }
    }
}