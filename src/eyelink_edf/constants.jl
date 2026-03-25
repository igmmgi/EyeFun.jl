"""
Constants and enumerations for EDF file format.
Based on SR Research EDF Access API definitions.
"""

# Eye codes
const EYE_LEFT = 0
const EYE_RIGHT = 1
const EYE_BINOCULAR = 2

# Recording state
const RECORDING_END = 0
const RECORDING_START = 1

# Record types
const RECORD_SAMPLES = 1
const RECORD_EVENTS = 2
const RECORD_BOTH = 3

# Pupil types
const PUPIL_AREA = 0
const PUPIL_DIAMETER = 1

# Recording modes
const MODE_PUPIL = 0
const MODE_CR = 1  # Corneal Reflection

# Position types
const POS_GAZE = 0
const POS_HREF = 1
const POS_RAW = 2

# Event types
const EVENT_STARTPARSE = 1
const EVENT_ENDPARSE = 2
const EVENT_BREAKPARSE = 10
const EVENT_STARTBLINK = 3
const EVENT_ENDBLINK = 4
const EVENT_STARTSACC = 5
const EVENT_ENDSACC = 6
const EVENT_STARTFIX = 7
const EVENT_ENDFIX = 8
const EVENT_FIXUPDATE = 9
const EVENT_STARTSAMPLES = 15
const EVENT_ENDSAMPLES = 16
const EVENT_STARTEVENTS = 17
const EVENT_ENDEVENTS = 18
const EVENT_MESSAGEEVENT = 24
const EVENT_BUTTONEVENT = 25
const EVENT_INPUTEVENT = 28
const EVENT_LOST_DATA = 0x3F

# Trial markers
const DEFAULT_START_MARKER = "TRIALID"
const DEFAULT_END_MARKER = "TRIAL_RESULT"
