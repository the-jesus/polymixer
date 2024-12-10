import struct
import sys

class ZipFileParser:
    def __init__(self, filepath):
        self.filepath = filepath

    def parse_eocd(self):
        with open(self.filepath, 'rb') as f:
            f.seek(-22, 2)  # EOCD should be within the last 22 bytes normally
            eocd = f.read(22)

            # Check for EOCD signature
            if eocd[:4] != b'\x50\x4b\x05\x06':
                raise ValueError("EOCD signature not found")

            # Unpack EOCD structure
            (signature,
             disk_number,
             disk_with_cd,
             total_entries_disk,
             total_entries,
             size_cd,
             offset_cd,
             comment_length) = struct.unpack('<IHHHHIIH', eocd)

            return {
                'disk_number': disk_number,
                'disk_with_cd': disk_with_cd,
                'total_entries_disk': total_entries_disk,
                'total_entries': total_entries,
                'size_cd': size_cd,
                'offset_cd': offset_cd,
                'comment_length': comment_length
            }

    def list_files(self):
        eocd = self.parse_eocd()

        print(eocd)

        with open(self.filepath, 'rb') as f:
            # Seek to the Central Directory
            f.seek(eocd['offset_cd'])

            files = []
            for _ in range(eocd['total_entries']):
                # Read Central Directory File Header signature
                header = f.read(46)  # Fixed size of CDFH without filename, extra field, and comment

                if header[:4] != b'\x50\x4b\x01\x02':
                    raise ValueError("CDFH signature not found")

                # Unpack fixed-size CDFH structure
                (
                    signature,

                    version_made,
                    version_needed,
                    flags,
                    compression,
                    mod_time,
                    mod_date,

                    crc32,
                    compressed_size,
                    uncompressed_size,

                    filename_length,
                    extra_length,
                    comment_length,
                    disk_number_start,
                    internal_attrs,

                    external_attrs,
                    offset_lfh
                ) = struct.unpack('<IHHHHHHIIIHHHHHII', header)

                print({
                    'signature': hex(signature),
                    'version_made': version_made,
                    'version_needed': version_needed,
                    'flags': flags,
                    'compression': compression,
                    'mod_time': mod_time,
                    'mod_date': mod_date,
                    'crc32': hex(crc32),
                    'compressed_size': compressed_size,
                    'uncompressed_size': uncompressed_size,
                    'filename_length': filename_length,
                    'extra_length': extra_length,
                    'comment_length': comment_length,
                    'disk_number_start': disk_number_start,
                    'internal_attrs': internal_attrs,
                    'external_attrs': hex(external_attrs),
                    'offset_lfh': offset_lfh,
                })

                # Read filename
                filename = f.read(filename_length).decode('utf-8')

                # Skip extra field and file comment
                f.seek(extra_length + comment_length, 1)

                files.append({
                    'filename': filename,
                    'compressed_size': compressed_size,
                    'uncompressed_size': uncompressed_size,
                    'crc32': crc32,
                    'offset_lfh': offset_lfh
                })

            return files

if __name__ == "__main__":
    filepath = sys.argv[1] or "example.zip"  # Replace with your ZIP file path
    parser = ZipFileParser(filepath)

    try:
        files = parser.list_files()
        print("Files in ZIP:")
        for file in files:
            print(f"- {file['filename']} (Compressed: {file['compressed_size']} bytes, Uncompressed: {file['uncompressed_size']} bytes, CRC32: {file['crc32']:08x})")
    except Exception as e:
        print(f"Error: {e}")
