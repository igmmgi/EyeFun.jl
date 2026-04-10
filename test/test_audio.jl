
# Simple cross-platform WAV player — no dependencies
# Run with: julia test_audio.jl

function play_wav(path::String)
    @async begin
        try
            if Sys.islinux()
                for player in ("pw-play", "paplay", "aplay")
                    !isnothing(Sys.which(player)) || continue
                    run(pipeline(`$player $path`, stderr=devnull), wait=true)
                    return
                end
                @warn "No audio player found (tried pw-play, paplay, aplay)"
            elseif Sys.isapple()
                run(`afplay $path`, wait=true)
            elseif Sys.iswindows()
                run(`powershell -c "(New-Object Media.SoundPlayer '$path').PlaySync()"`, wait=true)
            end
        catch e
            println("[play_wav] Error: ", e)
        end
    end
end

wav_file = joinpath(@__DIR__, "test.wav")
println("Playing: $wav_file")
t = play_wav(wav_file)
wait(t)
println("Done.")
