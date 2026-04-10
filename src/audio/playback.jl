"""
    list_audio_devices()

Prints a list of all available audio devices on the system. Use these string outputs
for the `audio_device` keyword in `play_wav`.
"""
function list_audio_devices()
    for dev in PortAudio.devices()
        println(dev.name)
    end
end

const _CACHED_AUDIO_DEVICE = Ref{Union{String, Nothing}}(nothing)
const _AUDIO_DEVICE_RESOLVED = Ref(false)

"""
    get_best_audio_device()

Scans audio hardware and returns the name of the best available
analog/speaker device, avoiding HDMI outputs. 
"""
function get_best_audio_device()
    if _AUDIO_DEVICE_RESOLVED[]
        return _CACHED_AUDIO_DEVICE[]
    end

    devices = PortAudio.devices()

    for dev in devices
        name_lower = lowercase(dev.name)
        if occursin("pulse", name_lower) || occursin("default", name_lower)
            _CACHED_AUDIO_DEVICE[] = dev.name
            _AUDIO_DEVICE_RESOLVED[] = true
            return dev.name
        end
    end

    for dev in devices
        name_lower = lowercase(dev.name)
        has_good_keyword = occursin("analog", name_lower) || occursin("built-in", name_lower) || occursin("speakers", name_lower)
        is_hdmi = occursin("hdmi", name_lower) || occursin("displayport", name_lower)

        if has_good_keyword && !is_hdmi
            _CACHED_AUDIO_DEVICE[] = dev.name
            _AUDIO_DEVICE_RESOLVED[] = true
            return dev.name
        end
    end

    _AUDIO_DEVICE_RESOLVED[] = true
    return nothing
end

"""
    play_wav(audio; audio_device=nothing)

Plays audio asynchronously. `audio` can be an absolute path string or a
`(data, samplerate)` tuple from FileIO.
"""
function play_wav(audio; audio_device=nothing)
    @async begin
        try
            if audio isa Tuple
                data, fs = audio
            elseif audio isa String
                data, fs = WAV.wavread(audio)
            else
                throw(ArgumentError("Expected an absolute file path string or a parsed audio Tuple"))
            end

            target_device = isnothing(audio_device) ? get_best_audio_device() : audio_device

            if isnothing(target_device)
                PortAudio.PortAudioStream(0, 1; samplerate=fs) do stream
                    write(stream, data)
                end
            else
                PortAudio.PortAudioStream(target_device, 0, 1; samplerate=fs) do stream
                    write(stream, data)
                end
            end
        catch e
            println("\n[play_wav] Audio Execution Error: ", e)
        end
    end
end
