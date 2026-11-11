"""
    _estimate_sample_rate(df::DataFrame) -> Float64

Estimate sample rate from the data by looking at median inter-sample interval.
Used as a fallback when recording metadata does not contain sample rate.
"""
function _estimate_sample_rate(df::DataFrame)
    nrow(df) <= 1 && return 1000.0
    return _estimate_sample_rate_ms(df[!, :time]; fallback = 1000.0)
end

@inline _safe_event_dur_u32(st::UInt32, en::UInt32)::UInt32 =
    en >= st ? (en - st + UInt32(1)) : UInt32(0)

function _extract_edf_screen_res_typed(
    msgs::AbstractVector{<:AbstractString},
    types::Union{AbstractVector{<:Integer},Nothing},
)
    fallback = (1920, 1080)
    gaze_coords_res = nothing
    has_types = !isnothing(types)

    @inbounds for i in eachindex(msgs)
        if has_types && types[i] != EVENT_MESSAGEEVENT
            continue
        end
        m = msgs[i]
        isempty(m) && continue
        s = lstrip(m)
        if startswith(s, "DISPLAY_COORDS")
            parts = split(s)
            if length(parts) >= 5
                right = tryparse(Float64, parts[4])
                bottom = tryparse(Float64, parts[5])
                if !isnothing(right) && !isnothing(bottom)
                    return (round(Int, right) + 1, round(Int, bottom) + 1)
                end
            end
        elseif isnothing(gaze_coords_res) && startswith(s, "GAZE_COORDS")
            parts = split(s)
            if length(parts) >= 5
                right = tryparse(Float64, parts[4])
                bottom = tryparse(Float64, parts[5])
                if !isnothing(right) && !isnothing(bottom)
                    gaze_coords_res = (round(Int, right) + 1, round(Int, bottom) + 1)
                end
            end
        end
    end
    return something(gaze_coords_res, fallback)
end

function _extract_edf_screen_res(events::DataFrame)
    (nrow(events) == 0 || !hasproperty(events, :message)) && return (1920, 1080)
    types = hasproperty(events, :type) ? events[!, :type] : nothing
    return _extract_edf_screen_res_typed(events[!, :message], types)
end

function _extract_sr_from_vec(srs::AbstractVector)
    @inbounds for r in srs
        !ismissing(r) && 100.0 <= Float64(r) <= 2000.0 && return Float64(r)
    end
    @inbounds for r in srs
        !ismissing(r) && Float64(r) > 0.0 && return Float64(r)
    end
    return 0.0
end

function _extract_edf_sample_rate(recordings::DataFrame, samples::Union{DataFrame,Nothing})
    if nrow(recordings) > 0 && hasproperty(recordings, :sample_rate)
        sr = _extract_sr_from_vec(recordings[!, :sample_rate])
        sr > 0.0 && return sr
    end
    if !isnothing(samples) && nrow(samples) > 0
        return _estimate_sample_rate(samples)
    end
    return 1000.0
end

function _populate_edf_metadata!(edf::EDFFile)
    edf.sample_rate = _extract_edf_sample_rate(edf.recordings, edf.samples)
    edf.screen_res = _extract_edf_screen_res(edf.events)
    return edf
end

function recordings_to_dataframe(recordings::Vector{EDFRecording})
    n = length(recordings)
    n == 0 && return DataFrame()
    return DataFrame(
        time = UInt32[r.time for r in recordings],
        sample_rate = Float32[r.sample_rate for r in recordings],
        eflags = UInt16[r.eflags for r in recordings],
        sflags = UInt16[r.sflags for r in recordings],
        state = UInt8[r.state for r in recordings],
        record_type = UInt8[r.record_type for r in recordings],
        pupil_type = UInt8[r.pupil_type for r in recordings],
        recording_mode = UInt8[r.recording_mode for r in recordings],
        filter_type = UInt8[r.filter_type for r in recordings],
        pos_type = UInt8[r.pos_type for r in recordings],
        eye = UInt8[r.eye for r in recordings],
        trial = Union{Int,Missing}[
            isnothing(r.trial) ? missing : r.trial for r in recordings
        ];
        copycols = false,
    )
end

function _find_event_indices(types::AbstractVector{<:Integer}, target::Integer)
    idx = Int[]
    @inbounds for i in eachindex(types)
        types[i] == target && push!(idx, i)
    end
    return idx
end

"""
    parse_saccades(events::DataFrame)

Extract saccade events from the events DataFrame.
"""
function parse_saccades(events::DataFrame)
    nrow(events) == 0 && return DataFrame()
    idx = _find_event_indices(events.type, EVENT_ENDSACC)
    isempty(idx) && return DataFrame()

    st = events.sttime[idx]
    en = events.entime[idx]
    dur = _safe_event_dur_u32.(st, en)

    out = DataFrame(sttime = st, entime = en, duration = dur; copycols = false)
    for c in (
        :hstx,
        :hsty,
        :gstx,
        :gsty,
        :henx,
        :heny,
        :genx,
        :geny,
        :havx,
        :havy,
        :gavx,
        :gavy,
        :ampl,
        :pvel,
        :svel,
        :evel,
        :eye,
    )
        if hasproperty(events, c)
            out[!, c] = events[!, c][idx]
        end
    end
    return out
end

"""
    parse_fixations(events::DataFrame)

Extract fixation events from the events DataFrame.
"""
function parse_fixations(events::DataFrame)
    nrow(events) == 0 && return DataFrame()
    idx = _find_event_indices(events.type, EVENT_ENDFIX)
    isempty(idx) && return DataFrame()

    st = events.sttime[idx]
    en = events.entime[idx]
    dur = _safe_event_dur_u32.(st, en)

    out = DataFrame(sttime = st, entime = en, duration = dur; copycols = false)
    for c in (
        :hstx,
        :hsty,
        :gstx,
        :gsty,
        :henx,
        :heny,
        :genx,
        :geny,
        :havx,
        :havy,
        :gavx,
        :gavy,
        :ava,
        :eye,
    )
        if hasproperty(events, c)
            out[!, c] = events[!, c][idx]
        end
    end
    return out
end

function _build_sacc_prefix_max(
    sacc_st::Vector{UInt32},
    sacc_en::Vector{UInt32},
)
    ns = length(sacc_st)
    ns == 0 && return UInt32[], UInt32[]
    if !issorted(sacc_st)
        perm = sortperm(sacc_st)
        sacc_st = sacc_st[perm]
        sacc_en = sacc_en[perm]
    end
    pref_max = Vector{UInt32}(undef, ns)
    cur = UInt32(0)
    @inbounds for i = 1:ns
        if sacc_en[i] > cur
            cur = sacc_en[i]
        end
        pref_max[i] = cur
    end
    return sacc_st, pref_max
end

@inline function _lookup_wrapping_sacc_end(
    blink_start::UInt32,
    sacc_st::Vector{UInt32},
    pref_max::Vector{UInt32},
)
    k = searchsortedlast(sacc_st, blink_start)
    return k >= 1 ? max(blink_start, @inbounds(pref_max[k])) : blink_start
end

function _resolve_binary_blinks!(
    result_sttime::Vector{UInt32},
    result_entime::Vector{UInt32},
    b_st::AbstractVector{<:Integer},
    result_eye::AbstractVector{<:Integer},
    s_idx::Vector{Int},
    ev_st::AbstractVector{<:Integer},
    ev_en::AbstractVector{<:Integer},
    ev_eye::AbstractVector{<:Integer},
    sam_times::Vector{UInt32},
    gxL_col::Vector{Float32},
    gxR_col::Vector{Float32},
)
    nb = length(result_sttime)
    ns = length(s_idx)
    st_all = Vector{UInt32}(undef, ns)
    en_all = Vector{UInt32}(undef, ns)
    st_L = UInt32[]
    en_L = UInt32[]
    st_R = UInt32[]
    en_R = UInt32[]
    @inbounds for j = 1:ns
        k = s_idx[j]
        st_k = UInt32(ev_st[k])
        en_k = UInt32(ev_en[k])
        ey_k = Int16(ev_eye[k])
        st_all[j] = st_k
        en_all[j] = en_k
        if ey_k == Int16(EYE_LEFT)
            push!(st_L, st_k)
            push!(en_L, en_k)
        elseif ey_k == Int16(EYE_RIGHT)
            push!(st_R, st_k)
            push!(en_R, en_k)
        end
    end
    st_all, pref_all = _build_sacc_prefix_max(st_all, en_all)
    st_L, pref_L = _build_sacc_prefix_max(st_L, en_L)
    st_R, pref_R = _build_sacc_prefix_max(st_R, en_R)

    default_gaze = !isempty(gxL_col) ? gxL_col : gxR_col

    @inbounds for i = 1:nb
        blink_start = UInt32(b_st[i])
        result_sttime[i] = blink_start
        b_eye = Int16(result_eye[i])

        sacc_end = if b_eye == Int16(EYE_LEFT) && !isempty(st_L)
            se = _lookup_wrapping_sacc_end(blink_start, st_L, pref_L)
            se > blink_start ? se : _lookup_wrapping_sacc_end(blink_start, st_all, pref_all)
        elseif b_eye == Int16(EYE_RIGHT) && !isempty(st_R)
            se = _lookup_wrapping_sacc_end(blink_start, st_R, pref_R)
            se > blink_start ? se : _lookup_wrapping_sacc_end(blink_start, st_all, pref_all)
        else
            _lookup_wrapping_sacc_end(blink_start, st_all, pref_all)
        end

        gaze_col = if b_eye == Int16(EYE_RIGHT) && !isempty(gxR_col)
            gxR_col
        elseif b_eye == Int16(EYE_LEFT) && !isempty(gxL_col)
            gxL_col
        else
            default_gaze
        end

        if !isempty(gaze_col)
            lo = searchsortedfirst(sam_times, blink_start)
            hi = searchsortedlast(sam_times, sacc_end)
            last_nan = blink_start
            for j = lo:hi
                if isnan(gaze_col[j])
                    last_nan = sam_times[j]
                end
            end
            result_entime[i] = last_nan
        else
            result_entime[i] = sacc_end
        end
    end
    return nothing
end

@inline _as_u32_vec(v::Vector{UInt32})::Vector{UInt32} = v
function _as_u32_vec(v::AbstractVector)::Vector{UInt32}
    out = Vector{UInt32}(undef, length(v))
    @inbounds for i in eachindex(v, out)
        out[i] = UInt32(v[i])
    end
    return out
end
@inline function _nonempty_f32_eye(v::Vector{Float32})::Vector{Float32}
    @inbounds for x in v
        !isnan(x) && return v
    end
    return Float32[]
end
function _nonempty_f32_eye(v::AbstractVector)::Vector{Float32}
    has_valid = false
    @inbounds for x in v
        if !ismissing(x) && !isnan(Float32(x))
            has_valid = true
            break
        end
    end
    has_valid || return Float32[]
    out = Vector{Float32}(undef, length(v))
    @inbounds for i in eachindex(v, out)
        x = v[i]
        out[i] = ismissing(x) ? Float32(NaN) : Float32(x)
    end
    return out
end

function _all_equal_at_indices(
    st::AbstractVector{<:Integer},
    en::AbstractVector{<:Integer},
    b_idx::Vector{Int},
)::Bool
    @inbounds for i in b_idx
        st[i] == en[i] || return false
    end
    return true
end

function _dedupe_and_merge_blinks(
    raw_st::Vector{UInt32},
    raw_en::Vector{UInt32},
    raw_eye::Vector{T},
)::Tuple{Vector{UInt32},Vector{UInt32},Vector{T}} where {T<:Integer}
    nb = length(raw_st)
    nb <= 1 && return (raw_st, raw_en, raw_eye)

    perm = sortperm(
        1:nb;
        by = i -> (@inbounds(raw_eye[i]), @inbounds(raw_en[i]), @inbounds(raw_st[i])),
    )
    u_st = Vector{UInt32}(undef, nb)
    u_en = Vector{UInt32}(undef, nb)
    u_eye = Vector{T}(undef, nb)
    nu = 0
    @inbounds for idx in perm
        st_i = raw_st[idx]
        en_i = raw_en[idx]
        ey_i = raw_eye[idx]
        if nu == 0 || ey_i != u_eye[nu] || en_i != u_en[nu]
            nu += 1
            u_st[nu] = st_i
            u_en[nu] = en_i
            u_eye[nu] = ey_i
        end
    end
    resize!(u_st, nu)
    resize!(u_en, nu)
    resize!(u_eye, nu)
    nu <= 1 && return (u_st, u_en, u_eye)

    perm2 = sortperm(1:nu; by = i -> (@inbounds(u_eye[i]), @inbounds(u_st[i])))
    merged_st = sizehint!(UInt32[], nu)
    merged_en = sizehint!(UInt32[], nu)
    merged_eye = sizehint!(T[], nu)
    @inbounds begin
        i1 = perm2[1]
        cur_st = u_st[i1]
        cur_en = u_en[i1]
        cur_eye = u_eye[i1]
        for k = 2:nu
            ik = perm2[k]
            if u_eye[ik] == cur_eye && u_st[ik] <= cur_en + UInt32(1)
                cur_en = max(cur_en, u_en[ik])
            else
                push!(merged_st, cur_st)
                push!(merged_en, cur_en)
                push!(merged_eye, cur_eye)
                cur_st = u_st[ik]
                cur_en = u_en[ik]
                cur_eye = u_eye[ik]
            end
        end
        push!(merged_st, cur_st)
        push!(merged_en, cur_en)
        push!(merged_eye, cur_eye)
    end
    return (merged_st, merged_en, merged_eye)
end

function _parse_blinks_typed(
    ev_type::AbstractVector{<:Integer},
    ev_st::AbstractVector{<:Integer},
    ev_en::AbstractVector{<:Integer},
    ev_eye::AbstractVector{T},
    samples::Union{DataFrame,Nothing},
    eye_filter::Union{Nothing,Integer},
) where {T<:Integer}
    b_idx = _find_event_indices(ev_type, EVENT_ENDBLINK)
    if !isnothing(eye_filter) && !isempty(b_idx)
        tgt = Int16(eye_filter)
        filter!(i -> begin
            ek = Int16(@inbounds(ev_eye[i]))
            ek == tgt || ek == Int16(EYE_BINOCULAR) || ek < Int16(0)
        end, b_idx)
    end
    isempty(b_idx) && return DataFrame()

    nb = length(b_idx)
    b_st = Vector{UInt32}(undef, nb)
    init_eye = Vector{T}(undef, nb)
    @inbounds for i = 1:nb
        idx = b_idx[i]
        b_st[i] = UInt32(ev_st[idx])
        init_eye[i] = ev_eye[idx]
    end

    is_binary = _all_equal_at_indices(ev_st, ev_en, b_idx)
    init_st = Vector{UInt32}(undef, nb)
    init_en = Vector{UInt32}(undef, nb)

    if is_binary
        s_idx = _find_event_indices(ev_type, EVENT_ENDSACC)
        has_samples = !isnothing(samples) && nrow(samples) > 0
        sam_times = has_samples ? _as_u32_vec(samples[!, :time]) : UInt32[]
        gxL_col =
            (has_samples && hasproperty(samples, :gxL)) ?
            _nonempty_f32_eye(samples[!, :gxL]) : Float32[]
        gxR_col =
            (has_samples && hasproperty(samples, :gxR)) ?
            _nonempty_f32_eye(samples[!, :gxR]) : Float32[]

        _resolve_binary_blinks!(
            init_st,
            init_en,
            b_st,
            init_eye,
            s_idx,
            ev_st,
            ev_en,
            ev_eye,
            sam_times,
            gxL_col,
            gxR_col,
        )
    else
        @inbounds for i = 1:nb
            init_st[i] = b_st[i]
            init_en[i] = UInt32(ev_en[b_idx[i]])
        end
    end

    final_st, final_en, final_eye =
        (is_binary && nb > 1) ? _dedupe_and_merge_blinks(init_st, init_en, init_eye) :
        (init_st, init_en, init_eye)

    return DataFrame(
        sttime = final_st,
        entime = final_en,
        duration = _safe_event_dur_u32.(final_st, final_en),
        eye = final_eye;
        copycols = false,
    )
end

"""
    parse_blinks(events::DataFrame; samples=nothing, eye_filter=nothing)

Extract blink events from the events DataFrame. When `eye_filter` is set to an
EyeLink eye code (`EYE_LEFT` or `EYE_RIGHT`), only blinks matching that eye (or
binocular / unspecified eye codes) are returned.
"""
function parse_blinks(
    events::DataFrame;
    samples::Union{DataFrame,Nothing} = nothing,
    eye_filter::Union{Nothing,Integer} = nothing,
)
    nrow(events) == 0 && return DataFrame()
    ev_eye = hasproperty(events, :eye) ? events[!, :eye] : fill(Int16(-1), nrow(events))
    return _parse_blinks_typed(
        events[!, :type],
        events[!, :sttime],
        events[!, :entime],
        ev_eye,
        samples,
        eye_filter,
    )
end

"""
    parse_messages(events::DataFrame)

Extract message events from the events DataFrame.
"""
function parse_messages(events::DataFrame)
    nrow(events) == 0 && return DataFrame()
    idx = _find_event_indices(events.type, EVENT_MESSAGEEVENT)
    isempty(idx) && return DataFrame()
    return DataFrame(
        sttime = events.sttime[idx],
        message = events.message[idx],
        eye = events.eye[idx];
        copycols = false,
    )
end

function _parse_variables_typed(
    types::AbstractVector{<:Integer},
    msgs::AbstractVector{<:AbstractString},
    sttimes::AbstractVector{<:Integer},
)
    out_st = UInt32[]
    var_names = String[]
    var_values = String[]

    @inbounds for i in eachindex(types)
        types[i] == EVENT_MESSAGEEVENT || continue
        msg = msgs[i]
        occursin("TRIAL_VAR", msg) || continue

        s = lstrip(msg)
        if startswith(s, "!V")
            n_cu = ncodeunits(s)
            (n_cu == 2 || isspace(s[nextind(s, 2)])) || continue
            s = lstrip(SubString(s, 3))
        end
        startswith(s, "TRIAL_VAR") || continue
        n_cu = ncodeunits(s)
        if n_cu > 9
            c10 = s[10]
            (c10 == ' ' || c10 == '\t') || continue
            rest = strip(SubString(s, 10))
        else
            rest = SubString(s, 1, 0)
        end

        push!(out_st, UInt32(sttimes[i]))
        if isempty(rest)
            push!(var_names, "")
            push!(var_values, "")
        else
            sp = findfirst(c -> c == ' ' || c == '\t', rest)
            if isnothing(sp)
                push!(var_names, String(rest))
                push!(var_values, "")
            else
                push!(var_names, String(SubString(rest, 1, prevind(rest, sp))))
                push!(var_values, String(lstrip(SubString(rest, sp))))
            end
        end
    end

    isempty(out_st) && return DataFrame()
    return DataFrame(
        sttime = out_st,
        variable = var_names,
        value = var_values;
        copycols = false,
    )
end

"""
    parse_variables(events::DataFrame)

Extract trial variables from message events.
"""
function parse_variables(events::DataFrame)
    nrow(events) == 0 && return DataFrame()
    return _parse_variables_typed(events[!, :type], events[!, :message], events[!, :sttime])
end

"""
    variables(variables::DataFrame; trial_marker::Union{String,Nothing} = nothing) -> DataFrame

Pivot the long-format trial variables table (from `parse_variables`) into a wide
one-row-per-trial DataFrame where each unique variable name becomes a column.

# Trial boundary detection
- **Default** (`trial_marker=nothing`): Auto-detects trial boundaries by finding the
  first repeated variable name. When a variable already seen in the current batch
  appears again, a new trial starts.
- **Explicit** (`trial_marker="trial"`): Uses the specified variable name as the
  trial boundary marker. Each occurrence of that variable starts a new trial, and
  its value is stored in the `trial_label` column.

# Example
```julia
edf = read_eyelink("recording.edf")
raw_vars = EyeFun.parse_variables(edf.events)
conditions = variables(raw_vars; trial_marker="trial")
```
"""
function variables(variables::DataFrame; trial_marker::Union{String,Nothing} = nothing)
    if nrow(variables) == 0
        return DataFrame()
    end

    n = nrow(variables)
    var_names = variables.variable
    var_values = variables.value

    trial_of = Vector{Int}(undef, n)

    if isnothing(trial_marker)
        # Auto-detect: a new trial starts when a variable name repeats
        seen = Set{String}()
        current_trial = 1
        for i = 1:n
            if var_names[i] in seen
                current_trial += 1
                empty!(seen)
            end
            push!(seen, var_names[i])
            trial_of[i] = current_trial
        end
    else
        # Explicit: each occurrence of trial_marker starts a new trial
        current_trial = 0
        for i = 1:n
            if var_names[i] == trial_marker
                current_trial += 1
            end
            trial_of[i] = current_trial
        end
        # Rows before the first marker get trial 0 (filtered out below)
    end

    n_trials = maximum(trial_of)
    if n_trials == 0
        return DataFrame()
    end

    result = DataFrame(trial = 1:n_trials)

    sttime_min = fill(typemax(UInt32), n_trials)
    sttime_max = fill(typemin(UInt32), n_trials)
    sttimes = variables.sttime
    for i = 1:n
        t = trial_of[i]
        t < 1 && continue
        sttime_min[t] = min(sttime_min[t], sttimes[i])
        sttime_max[t] = max(sttime_max[t], sttimes[i])
    end
    result.sttime_min = sttime_min
    result.sttime_max = sttime_max

    # If using explicit marker, store its value as trial_label and exclude it from columns
    exclude_var = trial_marker
    if !isnothing(trial_marker)
        labels = fill("", n_trials)
        for i = 1:n
            if var_names[i] == trial_marker && trial_of[i] >= 1
                labels[trial_of[i]] = var_values[i]
            end
        end
        result.trial_label = labels
    end

    col_order = String[]
    col_map = Dict{String,Int}()
    for i = 1:n
        vn = var_names[i]
        if !haskey(col_map, vn) && (isnothing(exclude_var) || vn != exclude_var)
            push!(col_order, vn)
            col_map[vn] = length(col_order)
        end
    end

    n_vars = length(col_order)
    col_vecs = [fill("", n_trials) for _ = 1:n_vars]
    @inbounds for i = 1:n
        tr = trial_of[i]
        tr < 1 && continue
        ci = get(col_map, var_names[i], 0)
        ci > 0 && (col_vecs[ci][tr] = String(strip(var_values[i])))
    end
    for ci = 1:n_vars
        result[!, Symbol(col_order[ci])] = col_vecs[ci]
    end

    return result
end

@inline function _clean_edf_msg_sub(raw::AbstractString)::SubString{String}
    n = ncodeunits(raw)
    n == 0 && return SubString("", 1, 0)
    has_nul = false
    @inbounds for i = 1:n
        if codeunit(raw, i) == 0x00
            has_nul = true
            break
        end
    end
    if has_nul
        return SubString(String(strip(replace(raw, '\0' => ""))))
    end
    if raw isa SubString{String}
        b1 = @inbounds codeunit(raw, 1)
        bn = @inbounds codeunit(raw, n)
        if b1 > 0x20 && bn > 0x20 && b1 < 0x7f && bn < 0x7f
            return raw
        end
        return strip(raw)
    elseif raw isa String
        s = strip(raw)
        return s isa SubString{String} ? s : SubString(s)
    end
    return SubString(String(strip(raw)))
end

@inline _copy_f32_col(col::Vector{Float32}, ::Int)::Vector{Float32} = copy(col)
function _copy_f32_col(col::AbstractVector, n::Int)::Vector{Float32}
    out = fill(Float32(NaN), n)
    @inbounds for i = 1:min(n, length(col))
        v = col[i]
        if !ismissing(v) && v isa Number
            out[i] = Float32(v)
        end
    end
    return out
end

function _count_valid_f32(col::Vector{Float32})::Int
    c = 0
    @inbounds for i in eachindex(col)
        !isnan(col[i]) && (c += 1)
    end
    return c
end

function _resolve_edf_eye_code(
    eye::Symbol,
    gxL::Vector{Float32},
    gxR::Vector{Float32},
    paL::Vector{Float32},
    paR::Vector{Float32},
    evs::DataFrame,
)::Int16
    if eye in (:left, :L, :l)
        return Int16(EYE_LEFT)
    elseif eye in (:right, :R, :r)
        return Int16(EYE_RIGHT)
    elseif eye != :auto
        error("Invalid eye=:$eye. Use :left, :right, :L, :R, or :auto.")
    end
    nL = _count_valid_f32(gxL)
    nR = _count_valid_f32(gxR)
    if nL == 0 && nR == 0
        nL = _count_valid_f32(paL)
        nR = _count_valid_f32(paR)
    end
    if nL == 0 && nR == 0 && nrow(evs) > 0 && hasproperty(evs, :eye)
        ev_eye = evs[!, :eye]
        @inbounds for i in eachindex(ev_eye)
            ek = ev_eye[i]
            if ek == EYE_LEFT
                nL += 1
            elseif ek == EYE_RIGHT
                nR += 1
            end
        end
    end
    return nL >= nR ? Int16(EYE_LEFT) : Int16(EYE_RIGHT)
end

@inline _copy_trial_col(col::Vector{Union{Int,Missing}}, ::Int)::Vector{Union{Int,Missing}} = copy(col)
function _copy_trial_col(col::AbstractVector, n::Int)::Vector{Union{Int,Missing}}
    out = Vector{Union{Int,Missing}}(missing, n)
    @inbounds for i = 1:min(n, length(col))
        v = col[i]
        !ismissing(v) && (out[i] = Int(v))
    end
    return out
end

function _fill_trial_var_col(
    src_col::AbstractVector{T},
    trial::Vector{Union{Int,Missing}},
    n::Int,
    n_ct::Int,
) where {T}
    dst_col = Vector{Union{T,Missing}}(missing, n)
    @inbounds for i = 1:n
        tr = trial[i]
        if !ismissing(tr) && 1 <= tr <= n_ct
            dst_col[i] = src_col[tr]
        end
    end
    return dst_col
end

function _stamp_events_direct!(
    times::Vector{UInt32},
    ev_type::AbstractVector{<:Integer},
    ev_eye::Union{AbstractVector{<:Integer},Nothing},
    target_eye::Int16,
    ev_st::AbstractVector{<:Integer},
    ev_en::AbstractVector{<:Integer},
    gavx::AbstractVector{<:Real},
    gavy::AbstractVector{<:Real},
    ava::AbstractVector{<:Real},
    gstx::AbstractVector{<:Real},
    gsty::AbstractVector{<:Real},
    genx::AbstractVector{<:Real},
    geny::AbstractVector{<:Real},
    ampl::Union{AbstractVector{<:Real},Nothing},
    pvel::Union{AbstractVector{<:Real},Nothing},
    msg_txt::AbstractVector{<:AbstractString},
    max_snap_ms::UInt32,
    in_fix::BitVector,
    fix_gavx::Vector{Float32},
    fix_gavy::Vector{Float32},
    fix_ava::Vector{Float32},
    fix_dur::Vector{Int32},
    in_sacc::BitVector,
    sacc_gstx::Vector{Float32},
    sacc_gsty::Vector{Float32},
    sacc_genx::Vector{Float32},
    sacc_geny::Vector{Float32},
    sacc_dur::Vector{Int32},
    sacc_ampl::Vector{Float32},
    sacc_pvel::Vector{Float32},
    message::Vector{S},
) where {S<:AbstractString}
    n = length(times)
    n == 0 && return nothing
    has_ampl = !isnothing(ampl)
    has_pvel = !isnothing(pvel)
    has_eye = !isnothing(ev_eye)
    burst_slots = Int[]
    burst_parts = Vector{SubString{String}}[]
    burst_lookup = Dict{Int,Int}()

    @inbounds for k in eachindex(ev_type)
        et = ev_type[k]
        if et == EVENT_ENDFIX
            if has_eye
                ek = Int16(ev_eye[k])
                (ek == target_eye || ek == Int16(EYE_BINOCULAR) || ek < Int16(0)) || continue
            end
            st_k = UInt32(ev_st[k])
            en_k = UInt32(ev_en[k])
            dur_ms = Int64(en_k) - Int64(st_k)
            (dur_ms < 0 || dur_ms > 30_000) && continue
            lo = searchsortedfirst(times, st_k)
            hi = searchsortedlast(times, en_k)
            if lo <= hi
                gx_k = Float32(gavx[k])
                gy_k = Float32(gavy[k])
                pa_k = Float32(ava[k])
                d_k = Int32(dur_ms + 1)
                for j = lo:hi
                    in_fix[j] = true
                    fix_gavx[j] = gx_k
                    fix_gavy[j] = gy_k
                    fix_ava[j] = pa_k
                    fix_dur[j] = d_k
                end
            end
        elseif et == EVENT_ENDSACC
            if has_eye
                ek = Int16(ev_eye[k])
                (ek == target_eye || ek == Int16(EYE_BINOCULAR) || ek < Int16(0)) || continue
            end
            st_k = UInt32(ev_st[k])
            en_k = UInt32(ev_en[k])
            dur_ms = Int64(en_k) - Int64(st_k)
            (dur_ms < 0 || dur_ms > 5_000) && continue
            lo = searchsortedfirst(times, st_k)
            hi = searchsortedlast(times, en_k)
            if lo <= hi
                sx_k = Float32(gstx[k])
                sy_k = Float32(gsty[k])
                ex_k = Float32(genx[k])
                ey_k = Float32(geny[k])
                d_k = Int32(dur_ms + 1)
                a_k = has_ampl ? Float32(ampl[k]) : Float32(NaN)
                v_k = has_pvel ? Float32(pvel[k]) : Float32(NaN)
                for j = lo:hi
                    in_sacc[j] = true
                    sacc_gstx[j] = sx_k
                    sacc_gsty[j] = sy_k
                    sacc_genx[j] = ex_k
                    sacc_geny[j] = ey_k
                    sacc_dur[j] = d_k
                    has_ampl && (sacc_ampl[j] = a_k)
                    has_pvel && (sacc_pvel[j] = v_k)
                end
            end
        elseif et == EVENT_MESSAGEEVENT
            ts = UInt32(ev_st[k])
            idx = searchsortedfirst(times, ts)
            match_idx = 0
            if idx <= n && times[idx] == ts
                match_idx = idx
            elseif max_snap_ms > UInt32(0)
                best_dist = typemax(UInt32)
                if idx <= n
                    d_hi = times[idx] - ts
                    if d_hi <= max_snap_ms
                        best_dist = d_hi
                        match_idx = idx
                    end
                end
                if idx > 1
                    d_lo = ts - times[idx-1]
                    if d_lo <= max_snap_ms && d_lo <= best_dist
                        match_idx = idx - 1
                    end
                end
            end
            if match_idx > 0
                clean = _clean_edf_msg_sub(msg_txt[k])
                isempty(clean) && continue
                if isempty(message[match_idx])
                    message[match_idx] = S === String ? String(clean) : clean
                else
                    bi = get(burst_lookup, match_idx, 0)
                    if bi == 0
                        prev_s = message[match_idx]
                        prev_sub = prev_s isa SubString{String} ? prev_s : SubString(String(prev_s))
                        push!(burst_slots, match_idx)
                        push!(burst_parts, SubString{String}[prev_sub, clean])
                        burst_lookup[match_idx] = length(burst_slots)
                    else
                        push!(burst_parts[bi], clean)
                    end
                end
            end
        end
    end

    if !isempty(burst_slots)
        if S === String
            buf = IOBuffer(; sizehint = 256)
            @inbounds for bi = 1:length(burst_slots)
                parts = burst_parts[bi]
                for pi = 1:length(parts)
                    pi > 1 && write(buf, "; ")
                    write(buf, parts[pi])
                end
                message[burst_slots[bi]] = String(take!(buf))
            end
        else
            nb = length(burst_slots)
            total_bytes = 0
            @inbounds for bi = 1:nb
                parts = burst_parts[bi]
                for pi = 1:length(parts)
                    total_bytes += sizeof(parts[pi])
                end
                total_bytes += 2 * (length(parts) - 1) + 1
            end
            arena = Vector{UInt8}(undef, total_bytes)
            offs = Vector{Int}(undef, nb)
            lens = Vector{Int}(undef, nb)
            w = 1
            @inbounds for bi = 1:nb
                parts = burst_parts[bi]
                offs[bi] = w
                for pi = 1:length(parts)
                    if pi > 1
                        arena[w] = UInt8(';')
                        arena[w+1] = UInt8(' ')
                        w += 2
                    end
                    p = parts[pi]
                    plen = sizeof(p)
                    if plen > 0
                        GC.@preserve arena p unsafe_copyto!(pointer(arena, w), pointer(p), plen)
                        w += plen
                    end
                end
                lens[bi] = w - offs[bi]
                arena[w] = 0x00
                w += 1
            end
            resize!(arena, w - 1)
            burst_str = String(arena)
            @inbounds for bi = 1:nb
                off = offs[bi]
                end_b = off + lens[bi] - 1
                last_i = codeunit(burst_str, end_b) < 0x80 ? end_b : thisind(burst_str, end_b)
                message[burst_slots[bi]] = SubString(burst_str, off, last_i)
            end
        end
    end

    return nothing
end

function _stamp_blinks!(
    times::Vector{UInt32},
    st::Vector{UInt32},
    en::Vector{UInt32},
    dur::Vector{UInt32},
    in_blink::BitVector,
    blink_dur::Vector{Int32},
)
    @inbounds for k in eachindex(st)
        en[k] >= st[k] || continue
        lo = searchsortedfirst(times, st[k])
        hi = searchsortedlast(times, en[k])
        if lo <= hi
            d_k = Int32(min(dur[k], UInt32(typemax(Int32))))
            for j = lo:hi
                in_blink[j] = true
                blink_dur[j] = d_k
            end
        end
    end
    return nothing
end

@inline function _msg_has_token(
    msg::AbstractString,
    target::AbstractString;
    allow_substring::Bool = false,
)
    isempty(msg) && return false
    msg == target && return true
    occursin(target, msg) || return false
    allow_substring && return true
    for part in eachsplit(msg, "; ")
        strip(part) == target && return true
    end
    return false
end

function _populate_trial_time_zero!(
    df::DataFrame,
    trial_time_zero::AbstractString;
    allow_substring::Bool = false,
)
    n = nrow(df)
    (n == 0 || !hasproperty(df, :message) || !hasproperty(df, :time)) && return df
    target = String(trial_time_zero)
    message = df[!, :message]
    times = df[!, :time]
    time_rel = Vector{Union{Float64,Missing}}(missing, n)

    if hasproperty(df, :trial)
        gcols = _has_multiple_participants(df) ? [:participant, :trial] : [:trial]
        for g in groupby(df, gcols; skipmissing = true)
            g_idx = parentindices(g)[1]
            t0 = NaN
            @inbounds for k in g_idx
                mk = message[k]
                if !ismissing(mk) &&
                   _msg_has_token(mk, target; allow_substring = allow_substring)
                    t0 = Float64(times[k])
                    break
                end
            end
            if !isnan(t0)
                @inbounds for k in g_idx
                    time_rel[k] = Float64(times[k]) - t0
                end
            end
        end
    else
        t0 = NaN
        @inbounds for k = 1:n
            mk = message[k]
            if !ismissing(mk) &&
               _msg_has_token(mk, target; allow_substring = allow_substring)
                t0 = Float64(times[k])
                break
            end
        end
        if !isnan(t0)
            @inbounds for k = 1:n
                time_rel[k] = Float64(times[k]) - t0
            end
        end
    end

    df.time_rel = time_rel
    return df
end

"""
    create_eyefun_data(edf::EDFFile; include_variables=true, trial_time_zero=nothing,
                       screen_res=nothing, screen_width_cm=nothing, viewing_distance_cm=nothing,
                       eye=:auto) -> EyeData

Construct an `EyeData` container from an `EDFFile` (returned by `read_eyelink`).

Joins tracker-native fixation, saccade, blink, and message events onto the
sample timeline. Each sample row is annotated with event membership (`in_fix`,
`in_sacc`, `in_blink`) and event attributes (`fix_gavx`, `sacc_gstx`, etc.).
In binocular recordings, events are stamped from the eye selected by `eye`
(`:auto` picks the eye with more valid gaze samples, tie-breaking to `:left`).

# Keyword Arguments
- `include_variables=true`: join `!V TRIAL_VAR` messages as extra columns
- `trial_time_zero=nothing`: message string that marks `t=0` within each trial;
  when set, a `time_rel` column (ms relative to that message) is added
- `screen_res=nothing`: override screen resolution; auto-detected from
  `DISPLAY_COORDS` / `GAZE_COORDS` message if `nothing`
- `screen_width_cm=nothing`: override physical screen width in cm
- `viewing_distance_cm=nothing`: override eye-to-screen distance in cm
- `eye=:auto`: target eye (`:auto`, `:left`, or `:right`) for stamping tracker-native events

# Example
```julia
raw = read_eyelink("session.edf")
ed  = EyeData(raw)          # uses tracker-native events
fixations(ed)
saccades(ed)
blinks(ed)
```
"""
function create_eyefun_data(
    edf::EDFFile;
    include_variables::Bool = true,
    trial_time_zero::Union{AbstractString,Nothing} = nothing,
    screen_res::Union{Tuple{Int,Int},Nothing} = nothing,
    screen_width_cm::Union{Real,Nothing} = nothing,
    viewing_distance_cm::Union{Real,Nothing} = nothing,
    eye::Symbol = :auto,
)
    samples = edf.samples
    if isnothing(samples) || nrow(samples) == 0
        error("No sample data in EDFFile.")
    end

    n = nrow(samples)
    times = _as_u32_vec(samples[!, :time])

    sr =
        edf.sample_rate > 0.0 ? edf.sample_rate :
        _extract_edf_sample_rate(edf.recordings, samples)
    if isnothing(screen_res)
        screen_res =
            edf.screen_res != (1920, 1080) ? edf.screen_res :
            (nrow(edf.events) > 0 ? _extract_edf_screen_res(edf.events) : edf.screen_res)
    end

    # Copy sample columns so in-place transforms on EyeData do not mutate edf.samples
    NaN32 = Float32(NaN)
    gxR = hasproperty(samples, :gxR) ? _copy_f32_col(samples[!, :gxR], n) : fill(NaN32, n)
    gyR = hasproperty(samples, :gyR) ? _copy_f32_col(samples[!, :gyR], n) : fill(NaN32, n)
    paR = hasproperty(samples, :paR) ? _copy_f32_col(samples[!, :paR], n) : fill(NaN32, n)
    gxL = hasproperty(samples, :gxL) ? _copy_f32_col(samples[!, :gxL], n) : fill(NaN32, n)
    gyL = hasproperty(samples, :gyL) ? _copy_f32_col(samples[!, :gyL], n) : fill(NaN32, n)
    paL = hasproperty(samples, :paL) ? _copy_f32_col(samples[!, :paL], n) : fill(NaN32, n)

    evs = edf.events
    target_eye = _resolve_edf_eye_code(eye, gxL, gxR, paL, paR, evs)

    trial =
        hasproperty(samples, :trial) ? _copy_trial_col(samples[!, :trial], n) :
        Vector{Union{Int,Missing}}(missing, n)

    time_f64 = Vector{Float64}(undef, n)
    @inbounds @simd for i = 1:n
        time_f64[i] = Float64(times[i])
    end

    in_fix = falses(n)
    fix_gavx = fill(NaN32, n)
    fix_gavy = fill(NaN32, n)
    fix_ava = fill(NaN32, n)
    fix_dur = fill(Int32(0), n)

    in_sacc = falses(n)
    sacc_gstx = fill(NaN32, n)
    sacc_gsty = fill(NaN32, n)
    sacc_genx = fill(NaN32, n)
    sacc_geny = fill(NaN32, n)
    sacc_dur = fill(Int32(0), n)
    sacc_ampl = fill(NaN32, n)
    sacc_pvel = fill(NaN32, n)

    in_blink = falses(n)
    blink_dur = fill(Int32(0), n)

    n_msgs = nrow(evs) > 0 ? count(==(EVENT_MESSAGEEVENT), evs[!, :type]) : 0
    message = n_msgs > 1024 ? fill(SubString("", 1, 0), n) : fill("", n)

    if nrow(evs) > 0
        max_snap_ms =
            sr > 0.0 ? UInt32(fld(round(Int, 1000.0 / sr), 2)) : UInt32(0)
        _stamp_events_direct!(
            times,
            evs[!, :type],
            hasproperty(evs, :eye) ? evs[!, :eye] : nothing,
            target_eye,
            evs[!, :sttime],
            evs[!, :entime],
            evs[!, :gavx],
            evs[!, :gavy],
            evs[!, :ava],
            evs[!, :gstx],
            evs[!, :gsty],
            evs[!, :genx],
            evs[!, :geny],
            hasproperty(evs, :ampl) ? evs[!, :ampl] : nothing,
            hasproperty(evs, :pvel) ? evs[!, :pvel] : nothing,
            evs[!, :message],
            max_snap_ms,
            in_fix,
            fix_gavx,
            fix_gavy,
            fix_ava,
            fix_dur,
            in_sacc,
            sacc_gstx,
            sacc_gsty,
            sacc_genx,
            sacc_geny,
            sacc_dur,
            sacc_ampl,
            sacc_pvel,
            message,
        )

        blink_df = parse_blinks(evs; samples = edf.samples, eye_filter = target_eye)
        if nrow(blink_df) > 0
            _stamp_blinks!(
                times,
                blink_df[!, :sttime],
                blink_df[!, :entime],
                blink_df[!, :duration],
                in_blink,
                blink_dur,
            )
        end
    end

    result = DataFrame(
        time = time_f64,
        trial = trial,
        participant = fill("", n),
        gxL = gxL,
        gyL = gyL,
        paL = paL,
        gxR = gxR,
        gyR = gyR,
        paR = paR,
        message = message,
        in_fix = in_fix,
        fix_gavx = fix_gavx,
        fix_gavy = fix_gavy,
        fix_ava = fix_ava,
        fix_dur = fix_dur,
        in_sacc = in_sacc,
        sacc_gstx = sacc_gstx,
        sacc_gsty = sacc_gsty,
        sacc_genx = sacc_genx,
        sacc_geny = sacc_geny,
        sacc_dur = sacc_dur,
        sacc_ampl = sacc_ampl,
        sacc_pvel = sacc_pvel,
        in_blink = in_blink,
        blink_dur = blink_dur;
        copycols = false,
    )

    if include_variables
        vars_long = parse_variables(edf.events)
        conds = nrow(vars_long) > 0 ? variables(vars_long) : DataFrame()
        n_ct = nrow(conds)
        if n_ct > 0 && hasproperty(result, :trial)
            for col_sym in propertynames(conds)
                col_sym in (:trial, :sttime_min, :sttime_max) && continue
                dst_col = _fill_trial_var_col(conds[!, col_sym], trial, n, n_ct)
                dst_sym = col_sym
                if hasproperty(result, dst_sym)
                    suffix = 1
                    while hasproperty(result, Symbol(col_sym, :_, suffix))
                        suffix += 1
                    end
                    dst_sym = Symbol(col_sym, :_, suffix)
                end
                result[!, dst_sym] = dst_col
            end
        end
    end

    if !isnothing(trial_time_zero)
        _populate_trial_time_zero!(result, trial_time_zero; allow_substring = false)
    end

    return EyeData(
        result;
        source = :eyelink,
        sample_rate = sr > 0.0 ? sr : 1000.0,
        screen_res = screen_res,
        screen_width_cm = something(screen_width_cm, edf.screen_width_cm),
        viewing_distance_cm = something(viewing_distance_cm, edf.viewing_distance_cm),
    )
end

function _norm_cal_eye(tok::AbstractString)::Symbol
    u = uppercase(strip(tok))
    u in ("LEFT", "L") && return :left
    u in ("RIGHT", "R") && return :right
    u in ("LR", "BOTH", "BINOCULAR") && return :both
    return :unknown
end

function _parse_cal_line!(
    out_time::Vector{Float64},
    out_kind::Vector{Symbol},
    out_model::Vector{String},
    out_eye::Vector{Symbol},
    out_outcome::Vector{String},
    out_avg::Vector{Float64},
    out_max::Vector{Float64},
    out_off_deg::Vector{Float64},
    out_off_x::Vector{Float64},
    out_off_y::Vector{Float64},
    out_msg::Vector{String},
    ts::Float64,
    raw_msg::AbstractString,
)
    s = strip(raw_msg)
    isempty(s) && return nothing

    if startswith(s, "!CAL")
        rest = strip(SubString(s, 5))
        if startswith(rest, "CALIBRATION")
            m = match(r"^CALIBRATION\s+(\S+)\s+\S+\s+(LEFT|RIGHT|L|R)\s+(\S+)"i, rest)
            if isnothing(m)
                m = match(
                    r"^CALIBRATION\s+\(([^,)]+)[^)]*\)\s+FOR\s+(LEFT|RIGHT|L|R)\s*:\s*(\S+)"i,
                    rest,
                )
            end
            if !isnothing(m)
                push!(out_time, ts)
                push!(out_kind, :calibration)
                push!(out_model, String(m.captures[1]))
                push!(out_eye, _norm_cal_eye(m.captures[2]))
                push!(out_outcome, uppercase(String(m.captures[3])))
                push!(out_avg, NaN)
                push!(out_max, NaN)
                push!(out_off_deg, NaN)
                push!(out_off_x, NaN)
                push!(out_off_y, NaN)
                push!(out_msg, String(s))
            end
        elseif startswith(rest, "VALIDATION")
            m = match(
                r"^VALIDATION\s+(\S+)\s+\S+\s+(LEFT|RIGHT|L|R)\s+(\S+)(?:\s+ERROR\s+([+-]?\d+(?:\.\d+)?)\s*avg\.?\s+([+-]?\d+(?:\.\d+)?)\s*max)?(?:\s+OFFSET\s+([+-]?\d+(?:\.\d+)?)\s*deg\.?\s+([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)\s*pix\.?)?"i,
                rest,
            )
            if !isnothing(m)
                avg_e = isnothing(m.captures[4]) ? NaN : parse(Float64, m.captures[4])
                max_e = isnothing(m.captures[5]) ? NaN : parse(Float64, m.captures[5])
                off_d = isnothing(m.captures[6]) ? NaN : parse(Float64, m.captures[6])
                off_x = isnothing(m.captures[7]) ? NaN : parse(Float64, m.captures[7])
                off_y = isnothing(m.captures[8]) ? NaN : parse(Float64, m.captures[8])
                push!(out_time, ts)
                push!(out_kind, :validation)
                push!(out_model, String(m.captures[1]))
                push!(out_eye, _norm_cal_eye(m.captures[2]))
                push!(out_outcome, uppercase(String(m.captures[3])))
                push!(out_avg, avg_e)
                push!(out_max, max_e)
                push!(out_off_deg, off_d)
                push!(out_off_x, off_x)
                push!(out_off_y, off_y)
                push!(out_msg, String(s))
            end
        end
    elseif startswith(s, "DRIFTCORRECT")
        rest = strip(SubString(s, 13))
        toks = split(rest)
        eye_sym = :unknown
        outcome = "OK"
        off_d = NaN
        off_x = NaN
        off_y = NaN
        max_e = NaN
        if !isempty(toks)
            eye_sym = _norm_cal_eye(toks[1])
            if length(toks) >= 2 && _norm_cal_eye(toks[2]) != :unknown
                eye_sym = _norm_cal_eye(toks[2])
            end
        end
        if occursin("ABORTED", rest)
            outcome = "ABORTED"
        elseif occursin("REPEATING", rest)
            outcome = "REPEATING"
            m_lr = match(r"L=([+-]?\d+(?:\.\d+)?)\s+R=([+-]?\d+(?:\.\d+)?)", rest)
            if !isnothing(m_lr)
                max_e = max(parse(Float64, m_lr.captures[1]), parse(Float64, m_lr.captures[2]))
            end
        end
        m_off = match(
            r"OFFSET\s+([+-]?\d+(?:\.\d+)?)\s*deg\.?\s+([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)\s*pix\.?"i,
            rest,
        )
        if !isnothing(m_off)
            off_d = parse(Float64, m_off.captures[1])
            off_x = parse(Float64, m_off.captures[2])
            off_y = parse(Float64, m_off.captures[3])
        end
        push!(out_time, ts)
        push!(out_kind, :drift_correct)
        push!(out_model, "")
        push!(out_eye, eye_sym)
        push!(out_outcome, outcome)
        push!(out_avg, NaN)
        push!(out_max, max_e)
        push!(out_off_deg, off_d)
        push!(out_off_x, off_x)
        push!(out_off_y, off_y)
        push!(out_msg, String(s))
    end
    return nothing
end

"""
    calibration_summary(source::Union{EDFFile,EyeData,DataFrame}) -> DataFrame

Extract EyeLink `!CAL CALIBRATION`, `!CAL VALIDATION`, and `DRIFTCORRECT`
quality messages into a summary `DataFrame`.

Returned columns:
- `time` (`Float64`): Message timestamp in ms
- `kind` (`Symbol`): `:calibration`, `:validation`, or `:drift_correct`
- `model` (`String`): Calibration grid model (e.g. `"HV9"`, `"HV5"`, `"HV3"`)
- `eye` (`Symbol`): `:left`, `:right`, `:both`, or `:unknown`
- `outcome` (`String`): Tracker outcome label (e.g. `"GOOD"`, `"FAIR"`, `"POOR"`, `"OK"`, `"REPEATING"`, `"ABORTED"`)
- `avg_error_deg` (`Float64`): Average validation error in degrees (`NaN` when not applicable)
- `max_error_deg` (`Float64`): Maximum validation/drift error in degrees (`NaN` when not applicable)
- `offset_deg` (`Float64`): Gaze offset magnitude in degrees (`NaN` when not applicable)
- `offset_x_px`, `offset_y_px` (`Float64`): Gaze offset in pixels (`NaN` when not applicable)
- `message` (`String`): Raw message text
"""
function calibration_summary(edf::EDFFile)::DataFrame
    return calibration_summary(edf.events)
end

function calibration_summary(ed::EyeData)::DataFrame
    msg_df = messages(ed)
    return calibration_summary(msg_df)
end

function calibration_summary(df::DataFrame)::DataFrame
    out_time = Float64[]
    out_kind = Symbol[]
    out_model = String[]
    out_eye = Symbol[]
    out_outcome = String[]
    out_avg = Float64[]
    out_max = Float64[]
    out_off_deg = Float64[]
    out_off_x = Float64[]
    out_off_y = Float64[]
    out_msg = String[]

    if nrow(df) > 0 && hasproperty(df, :message)
        msgs = df[!, :message]
        has_type = hasproperty(df, :type)
        types = has_type ? df[!, :type] : nothing
        tcol = hasproperty(df, :sttime) ? df[!, :sttime] : (hasproperty(df, :time) ? df[!, :time] : nothing)
        @inbounds for i in eachindex(msgs)
            has_type && types[i] != EVENT_MESSAGEEVENT && continue
            m = msgs[i]
            (ismissing(m) || isempty(m)) && continue
            (occursin("!CAL", m) || occursin("DRIFTCORRECT", m)) || continue
            ts = isnothing(tcol) || ismissing(tcol[i]) ? NaN : Float64(tcol[i])
            for part in eachsplit(m, "; ")
                _parse_cal_line!(
                    out_time,
                    out_kind,
                    out_model,
                    out_eye,
                    out_outcome,
                    out_avg,
                    out_max,
                    out_off_deg,
                    out_off_x,
                    out_off_y,
                    out_msg,
                    ts,
                    part,
                )
            end
        end
    end

    return DataFrame(
        time = out_time,
        kind = out_kind,
        model = out_model,
        eye = out_eye,
        outcome = out_outcome,
        avg_error_deg = out_avg,
        max_error_deg = out_max,
        offset_deg = out_off_deg,
        offset_x_px = out_off_x,
        offset_y_px = out_off_y,
        message = out_msg;
        copycols = false,
    )
end
