from memory_profiler import profile
from collections.abc import Sequence

class VirtualString(Sequence):
    def __init__(self):
        self.data = {}

    def __len__(self) -> int:
        return 100

    @profile
    def __setitem__(self, key, value):
        if isinstance(key, slice):
            self.data[(key.start, key.stop)] = value
        else:
            raise TypeError("Indexing must be done with slices")

    @profile
    def __getitem__(self, key):
        if not isinstance(key, slice):
            raise TypeError("Indexing must be done with slices")

        result = []
        # requested_range = range(key.start, key.stop)
        sorted_keys = sorted(self.data.keys(), key=lambda x: x[0])

        #for (start, stop), value in sorted_keys:
        pos = key.start
        for k in sorted_keys:
            (start, stop) = k
            print(start, stop)
            print(key)
            value = self.data[k]
            if stop < key.start or key.stop < start:
                continue

            padding_start = min(start, pos)
            overlap_start = max(start, key.start)
            result.append(b'.' * (overlap_start - padding_start))
            overlap_end = min(stop, key.stop)
            overlap_length = overlap_end - overlap_start
            value_start = overlap_start - start
            result.append(value[value_start:value_start + overlap_length])
            pos = overlap_end

        result.append(b'.' * (key.stop - pos))

        return b''.join(result)

    @profile
    def __bytes__(self):
        return bytes(self[0:])

# Beispiel
vstr = VirtualString()
vstr[100:110] = b'HelloWorld'
vstr[115:120] = b'Python'

#print(vstr[0::2])
#print(vstr[-10:300])
print(vstr[95:125])

#with open('/tmp/out', 'wb') as file:
#    file.write(bytes(vstr))
