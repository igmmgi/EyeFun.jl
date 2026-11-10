"""
    play_wav(path::AbstractString; audio_device=nothing, cleanup=false)
    play_wav(audio::Tuple{AbstractArray,Real}; audio_device=nothing)

Play a WAV file (or `(waveform_array, sample_rate)` buffer) asynchronously using
system audio player commands.

# Keyword Arguments
- `audio_device::Union{Nothing,AbstractString}=nothing`: optional output device/sink target
  forwarded to `pw-play --target`, `paplay --device`, or `aplay -D` on Linux.
- `cleanup::Bool=false`: remove `path` once playback finishes.
"""
function play_wav(
    path::AbstractString;
    audio_device::Union{Nothing,AbstractString} = nothing,
    cleanup::Bool = false,
    kwargs...,
)
    isfile(path) || throw(ArgumentError("WAV file not found: $path"))
    dev = isnothing(audio_device) || isempty(strip(audio_device)) ? nothing : String(audio_device)

    @async begin
        try
            if Sys.islinux()
                played = false
                for player in ("pw-play", "paplay", "aplay")
                    !isnothing(Sys.which(player)) || continue
                    cmd = if isnothing(dev)
                        `$player $path`
                    elseif player == "pw-play"
                        `$player --target $dev $path`
                    elseif player == "paplay"
                        `$player --device=$dev $path`
                    else
                        `$player -D $dev $path`
                    end
                    if success(pipeline(cmd, stderr = devnull))
                        played = true
                        break
                    end
                end
                !played && @warn "No working audio player found (tried pw-play, paplay, aplay)"
            elseif Sys.isapple()
                run(`afplay $path`, wait = true)
            elseif Sys.iswindows()
                escaped = replace(path, "'" => "''")
                run(
                    `powershell -c "(New-Object Media.SoundPlayer '$escaped').PlaySync()"`,
                    wait = true,
                )
            end
        catch e
            @warn "Audio playback failed" exception = e
        finally
            cleanup && isfile(path) && rm(path; force = true)
        end
    end
end

@inline function _sample_to_pcm16(s::Real)::Int16
    if s isa Int16
        return s
    elseif s isa UInt8
        return Int16((Int(s) - 128) * 256)
    elseif s isa Signed
        scale = Float64(typemax(typeof(s)))
        return round(Int16, clamp(Float64(s) / scale, -1.0, 1.0) * 32767.0)
    elseif s isa Unsigned
        half = (Float64(typemax(typeof(s))) + 1.0) / 2.0
        return round(Int16, clamp((Float64(s) - half) / half, -1.0, 1.0) * 32767.0)
    else
        v = Float64(s)
        clamped = clamp(isnan(v) ? 0.0 : v, -1.0, 1.0)
        return round(Int16, clamped * 32767.0)
    end
end

function _write_pcm16_wav(path::AbstractString, samples::AbstractArray, fs::Real)
    ndims(samples) in (1, 2) || throw(
        ArgumentError(
            "Audio waveform must be a 1D vector or 2D (frames × channels) matrix, got $(ndims(samples))D array.",
        ),
    )
    (isfinite(fs) && fs > 0) ||
        throw(ArgumentError("Audio sample rate must be positive and finite, got $fs."))

    n_frames = size(samples, 1)
    n_channels = ndims(samples) == 1 ? 1 : size(samples, 2)
    sr = UInt32(round(Int, fs))
    bytes_per_sample = UInt16(2)
    block_align = UInt16(n_channels * bytes_per_sample)
    byte_rate = sr * UInt32(block_align)
    data_bytes = UInt32(n_frames * Int(block_align))
    riff_size = UInt32(36) + data_bytes

    open(path, "w") do io
        write(io, b"RIFF")
        write(io, htol(riff_size))
        write(io, b"WAVE")
        write(io, b"fmt ")
        write(io, htol(UInt32(16)))            # PCM fmt chunk size
        write(io, htol(UInt16(1)))             # AudioFormat = 1 (PCM)
        write(io, htol(UInt16(n_channels)))
        write(io, htol(sr))
        write(io, htol(byte_rate))
        write(io, htol(block_align))
        write(io, htol(UInt16(16)))            # BitsPerSample = 16
        write(io, b"data")
        write(io, htol(data_bytes))

        buf = Vector{Int16}(undef, n_frames * n_channels)
        idx = 0
        @inbounds for i = 1:n_frames
            for c = 1:n_channels
                raw_s = ndims(samples) == 1 ? samples[i] : samples[i, c]
                idx += 1
                buf[idx] = htol(_sample_to_pcm16(raw_s))
            end
        end
        write(io, buf)
    end
    return path
end

function play_wav(audio::Tuple{AbstractArray,Real}; kwargs...)
    samples, fs = audio
    ndims(samples) in (1, 2) || throw(
        ArgumentError(
            "Audio waveform must be a 1D vector or 2D (frames × channels) matrix, got $(ndims(samples))D array.",
        ),
    )
    (isfinite(fs) && fs > 0) ||
        throw(ArgumentError("Audio sample rate must be positive and finite, got $fs."))
    tmp_path = tempname() * ".wav"
    _write_pcm16_wav(tmp_path, samples, fs)
    return play_wav(tmp_path; cleanup = true, kwargs...)
end

play_wav(samples::AbstractArray, fs::Real; kwargs...) = play_wav((samples, fs); kwargs...)
