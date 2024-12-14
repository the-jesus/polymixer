import sys

INTS = [
    0x13ab,
    0x13ac,
]

RECS = {
    0x0000: "ChapterDisplay",
    0x000e: "Slices",
    0x000f: "ChapterTrack",
    0x0020: "BlockGroup",
    0x0026: "BlockMore",
    0x002e: "TrackEntry",
    0x0036: "ChapterAtom",
    0x0037: "CueTrackPositions",
    0x003b: "CuePoint",
    0x005b: "CueReference",
    0x0060: "Video",
    0x0061: "Audio",
    0x0068: "TimeSlice",
    0x05b9: "EditionEntry",
    0x0dbb: "Seek",
    0x1034: "ContentCompression",
    0x1035: "ContentEncryption",
    0x1854: "SilentTracks",
    0x21a7: "AttachedFile",
    0x2240: "ContentEncoding",
    0x23c0: "Targets",
    0x2624: "TrackTranslate",
    0x26bf: "TrackTranslateCodec",
    0x27c8: "SimpleTag",
    0x2911: "ChapterProcessCommand",
    0x2924: "ChapterTranslate",
    0x2944: "ChapterProcess",
    0x2955: "ChapterProcessCodecID?",
    0x29bf: "ChapterTranslateCodec",
    0x2d80: "ContentEncodings",
    0x3373: "Tag",
    0x35a1: "BlockAdditions",
    0x3e5b: "SignatureElements",
    0x3e7b: "SignatureElementList",
    0x7670: "Projection",
    0x43a770: "Chapters",
    0x14d9b74: "SeekHead",
    0x254c367: "Tags",
    0x549a966: "Info",
    0x654ae6b: "Tracks",
    0x8538067: "SegmentHeader",
    0x941a469: "Attachments",
    0xa45dfa3: "EBMLHeader",
    0xb538667: "SignatureSlot",
    0xc53bb6b: "Cues",
    0xf43b675: "Cluster",
}

def read_vint(data, offset):
    length = 0
    value = 0
    first_byte = data[offset]

    while (first_byte >> (7 - length)) & 1 == 0 and length < 8:
        length += 1
    length += 1

    if length > 0:
        mask = (1 << (8 - length)) - 1
        value = first_byte & mask
        for i in range(1, length):
            value = (value << 8) + data[offset + i]

    return value, length

def parse_ebml(data, offset, end, level = 0):
    while offset < end:
        block_start = offset

        element_id, id_size = read_vint(data, offset)
        offset += id_size

        o = offset + 1

        element_size, size_size = read_vint(data, offset)
        offset += size_size

        if element_id in RECS:
            tag = RECS[element_id]
            print(("  " * level) + f"<{tag} offset={block_start} element_id={hex(element_id)} size={id_size}+{size_size}+{element_size}={id_size+size_size+element_size}>")
        else:
            value = data[o:(o + element_size)]
            if element_id in INTS:
                print(("  " * level) + f"<{hex(element_id)} offset={block_start} element_id={hex(element_id)} size={id_size}+{size_size}+{element_size}={id_size+size_size+element_size}>{int.from_bytes(value)} {value.hex()}</{hex(element_id)}>")
            else:
                print(("  " * level) + f"<{hex(element_id)} offset={block_start} element_id={hex(element_id)} size={id_size}+{size_size}+{element_size}={id_size+size_size+element_size}>{value}</{hex(element_id)}>")

        if element_id in RECS:
            parse_ebml(data, offset, offset + element_size, level + 1)

        offset += element_size

with open(sys.argv[1], 'rb') as f:
    ebml_data = f.read()

parse_ebml(ebml_data, 0, len(ebml_data))

