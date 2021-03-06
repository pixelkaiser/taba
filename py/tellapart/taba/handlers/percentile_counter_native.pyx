# Copyright 2012 TellApart, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Native Cython implementation of a percentile counter for Taba.
"""

import random

from tellapart.taba.taba_event import TABA_EVENT_IDX_VALUE

# Import C-library dependencies.
from libc.stdlib cimport qsort
from libc.string cimport memset

# Declare a typedef for "const void"; used by qsort() comparator functions.
cdef extern from *:
  ctypedef void const_void "const void"

cdef inline int int_min(int a, int b): return a if a <= b else b

# The percentiles that should be returned by the 'percentiles' attribute.
DEF NUM_PERCENTILES = 6
PERCENTILES = (0.25, 0.50, 0.75, 0.90, 0.95, 0.99)

ZERO_PERCENTILES = [0.0] * NUM_PERCENTILES
cdef float[NUM_PERCENTILES] FLOAT_PERCENTILES
cdef int i
for i in xrange(NUM_PERCENTILES):
  FLOAT_PERCENTILES[i] = PERCENTILES[i]

# The running sample size is fixed as a constant.
DEF RUNNING_SAMPLE_SIZE = 200

# A struct encapsulating percentile counter state for a single counter instance.
cdef struct PercentileCounterState:
  # The number of values recorded (i.e., the count).
  int num_values_recorded

  # The sum of the values recorded.
  float values_total

  # The running sample array.
  float running_sample[RUNNING_SAMPLE_SIZE]

def NewState():
  """Generate a new state binary string representing a newly allocated counter
  instance.

  Returns:
    A new state Python binary string object.
  """
  cdef PercentileCounterState state
  memset(&state, 0, sizeof(state))
  return _SerializeState(&state)

def FoldEvents(state_buffer, events):
  """Given a state buffer and a list of events for a single Client ID and Taba
  Name, fold the events into the state, and return the updated state buffer.

  Args:
    state_buffer - A state buffer of the type returned by NewState().
    events - A list of TabaEvent objects for a single Client and Taba Name.

  Returns:
    A state Python binary string object with the events folded in.
  """
  cdef float value

  cdef PercentileCounterState *decoded_state = _DeserializeState(state_buffer)
  for event in events:
    value = event[TABA_EVENT_IDX_VALUE][0]

    _ReservoirSample(decoded_state, value)
    decoded_state.num_values_recorded += 1
    decoded_state.values_total += value

  return _SerializeState(decoded_state)

def ProjectState(state_buffer):
  """Given a state buffer generated by this handler, generate a projection that
  can be aggregated. A projection must have the form {String : Object}.
  (e.g.: {'count': 100, 'total': 234})

  Args:
    state - A state buffer of the type returned by NewState().

  Returns:
    A dict of {String : Object} representing a projection of the given state.
  """
  cdef PercentileCounterState *decoded_state
  decoded_state = _DeserializeState(state_buffer)

  count = decoded_state.num_values_recorded
  total = decoded_state.values_total

  projection = {
    'count' : count,
    'total' : total,
    'average' : total / count if count != 0.0 else 0.0,
    'percentiles' : _GetPercentiles(decoded_state),
  }
  return projection

cdef _GetPercentiles(PercentileCounterState *state):
  """Compute percentile stats for the values accumulated thus far.

  Returns:
    A list of float percentile stats.
  """
  cdef int num_to_sort = int_min(state.num_values_recorded,
                                 RUNNING_SAMPLE_SIZE)
  cdef float pct
  cdef int idx

  if num_to_sort == 0:
    return ZERO_PERCENTILES

  qsort(state.running_sample, num_to_sort, sizeof(float), &_CompareFloats)

  values = []
  for pct in FLOAT_PERCENTILES:
    idx = <int> (pct * <float> num_to_sort)
    values.append(state.running_sample[idx])

  return values

cdef _SerializeState(PercentileCounterState *state):
  """Encode the given state struct into a Python binary string.

  Args:
    state - A pointer to a PercentileCounterState struct.

  Returns:
    An encoded Python binary string object.
  """
  cdef char* state_byte_ptr = <char*> state
  state_byte_string = state_byte_ptr[:sizeof(PercentileCounterState)]
  return state_byte_string

cdef PercentileCounterState* _DeserializeState(char *state_byte_string):
  """Decode the given state string into a PercentileCounterState object.

  Note that the string passed as an argument must remain alive as long as the
  returned PercentileCounterState is accessed/modified.

  Args:
    state_byte_string - A C string representing the encoded percentile counter
        state.

  Returns:
    A pointer to the decoded PercentileCounterState struct.
  """
  cdef PercentileCounterState* state = \
      <PercentileCounterState*> state_byte_string
  return state

cdef _ReservoirSample(PercentileCounterState *state, float value):
  """Add the given value to the accumulated reservoir sample.

  If 'running_sample_size' values have not yet been added, the given value will
  always be added.  If 'running_sample_size' values _have_ already been added,
  the given value will only be added with a diminishing probability.

  Args:
    value - The float value to record.
  """
  if state.num_values_recorded < RUNNING_SAMPLE_SIZE:
    state.running_sample[state.num_values_recorded] = value
    return

  prob_replace = (float(RUNNING_SAMPLE_SIZE) /
                  float(state.num_values_recorded + 1))
  if random.random() < prob_replace:
    # Choose a sample element at random, and replace it.
    index = random.randint(0, RUNNING_SAMPLE_SIZE - 1)
    state.running_sample[index] = value

cdef int _CompareFloats(const_void* a, const_void* b) nogil:
  """Comparison function for floats; used by qsort().
  """
  cdef float* af = <float*> a
  cdef float* bf = <float*> b

  if af[0] < bf[0]:
    return -1

  if af[0] > bf[0]:
    return 1

  return 0
