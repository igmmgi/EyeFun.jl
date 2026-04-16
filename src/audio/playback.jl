"""
    play_wav(path::String)

Plays a WAV file asynchronously using the native cross-platform audio player capabilities.
"""
function play_wav(path::String; kwargs...)
    @async begin
        try
            if Sys.islinux()
                for player in ("pw-play", "paplay", "aplay")
                    !isnothing(Sys.which(player)) || continue
                    run(pipeline(`$player $path`, stderr = devnull), wait = true)
                    return
                end
                @warn "No audio player found (tried pw-play, paplay, aplay)"
            elseif Sys.isapple()
                run(`afplay $path`, wait = true)
            elseif Sys.iswindows()
                run(
                    `powershell -c "(New-Object Media.SoundPlayer '$path').PlaySync()"`,
                    wait = true,
                )
            end
        catch e
            println("[play_wav] Error: ", e)
        end
    end
end
