# ── Preview Stimuli Dashboard ──────────────────────────────────────────────── #

"""
    plot_stimuli(stim::Dict; audio_device=nothing, resolution=(1920, 1080))

Generates an interactive Makie dashboard allowing the user to scroll through
all loaded stimuli and play audio natively. 

If audio playback fails or routes to the wrong hardware, you can explicitly
specify your ALSA/system device string (e.g. `audio_device="HD-Audio Generic: ALC887-VD Analog (hw:1,0)"`).
"""
function plot_stimuli(stim::Dict; audio_device=nothing, resolution=(1920, 1080))
    f = Figure(size=(800, 600))
    keys_list = collect(keys(stim))

    if isempty(keys_list)
        return f
    end

    # State observables
    filtered_keys = Observable{Vector{String}}(keys_list)

    # Header Row
    title_label = Label(f[1, 1], keys_list[1], font=:bold, fontsize=24, tellwidth=false)

    exts = unique([lowercase(splitext(k)[2]) for k in keys_list])
    opts = ["All"; sort(collect(exts))]
    menu = Menu(f[1, 2], options=opts, width=150)

    # Body
    ax = Axis(f[2, 1:2], aspect=DataAspect())
    hidespines!(ax)
    hidedecorations!(ax)
    
    # Freeze the camera limits to the exact monitor resolution so stimuli stay 1:1 natively sized!
    limits!(ax, 0, resolution[1], 0, resolution[2])

    # Controls
    play_button = Button(f[3, 1:2], label="", buttoncolor=:transparent, tellwidth=false)
    
    # Navigation Grid
    nav_grid = f[4, 1:2] = GridLayout()
    prev_button = Button(nav_grid[1, 1], label="< Prev", width=80)
    sl = Slider(nav_grid[1, 2], range=lift(x -> 1:max(1, length(x)), filtered_keys), startvalue=1)
    next_button = Button(nav_grid[1, 3], label="Next >", width=80)
    
    counter_label = Label(f[5, 1:2], "File 1 of $(length(keys_list))", fontsize=16, tellwidth=false)
    
    # Button callbacks
    on(prev_button.clicks) do _
        set_close_to!(sl, max(1, sl.value[] - 1))
    end
    
    on(next_button.clicks) do _
        set_close_to!(sl, min(length(filtered_keys[]), sl.value[] + 1))
    end

    # Reactive Filter Updates
    on(menu.selection) do sel
        if isnothing(sel) || sel == "All"
            filtered_keys[] = keys_list
        else
            filtered_keys[] = filter(k -> lowercase(splitext(k)[2]) == sel, keys_list)
        end
        # Snap slider back to 1 and force UI update
        set_close_to!(sl, 1)
        notify(sl.value)
    end

    on(sl.value) do idx
        empty!(ax)
        fk = filtered_keys[]

        if isempty(fk)
            title_label.text = "No Files Found"
            counter_label.text = "File 0 of 0"
            play_button.label = "Not Audio"
            play_button.buttoncolor = :gray80
            return
        end

        safe_idx = clamp(idx, 1, length(fk))
        k = fk[safe_idx]

        title_label.text = k
        counter_label.text = "File $(safe_idx) of $(length(fk))"

        val = stim[k]

        # Hide the button completely by default
        play_button.label = ""
        play_button.buttoncolor = :transparent

        if endswith(lowercase(k), ".wav")
            # Enable Button
            play_button.label = "▶ Play Audio"
            play_button.buttoncolor = :cornflowerblue
            text!(ax, resolution[1]/2, resolution[2]/2; text="Audio Track\nReady to Play", align=(:center, :center), fontsize=24)
        elseif typeof(val) <: AbstractMatrix
            # Geometrically center the image natively inside the 1920x1080 screen!
            img_rotated = rotr90(val)
            w, h = size(img_rotated)
            
            cx = resolution[1] / 2
            cy = resolution[2] / 2
            
            x_range = (cx - w/2) .. (cx + w/2)
            y_range = (cy - h/2) .. (cy + h/2)
            
            image!(ax, x_range, y_range, img_rotated)
        elseif typeof(val) <: String
            disp_txt = length(val) > 400 ? val[1:400] * "..." : val
            text!(ax, resolution[1]/2, resolution[2]/2; text=disp_txt, align=(:center, :center), fontsize=16, word_wrap_width=500)
        end
    end

    on(play_button.clicks) do _
        if play_button.label[] != "▶ Play Audio"
            return
        end

        idx = sl.value[]
        fk = filtered_keys[]

        if isempty(fk)
            return
        end

        safe_idx = clamp(idx, 1, length(fk))
        k = fk[safe_idx]
        val = stim[k]

        if endswith(lowercase(k), ".wav")
            play_wav(val; audio_device=audio_device)
        end
    end

    notify(sl.value)

    return f
end
