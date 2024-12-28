import sys
from hashlib import pbkdf2_hmac
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
import struct
import binascii
import crcmod

def hexdump(data, length=16):
    result = []
    for i in range(0, len(data), length):
        chunk = data[i:i+length]
        hex_part = ' '.join(f'{byte:02x}' for byte in chunk)
        ascii_part = ''.join((chr(byte) if 32 <= byte <= 126 else '.') for byte in chunk)
        result.append(f'{(i + 64):08x}  {hex_part:<{length*3}}  {ascii_part}')

    return '\n'.join(result)

def decrypt_truecrypt_header(file_path, password):
    with open(file_path, "rb") as f:
        data = f.read(512)
        salt = data[0:64]
        encrypted_header = data[64:]

    key = pbkdf2_hmac('ripemd160', password.encode(), salt, 2000, 64)

    aes_key1 = key[:32]
    aes_key2 = key[32:]

    tweak = b'\x00' * 16

    xts_cipher = Cipher(algorithms.AES(aes_key1 + aes_key2), modes.XTS(tweak), backend=default_backend())
    decryptor = xts_cipher.decryptor()

    decrypted_header = decryptor.update(encrypted_header) + decryptor.finalize()

    return decrypted_header

def is_valid_truecrypt_header(decrypted_header):
    return decrypted_header[:4] == b'TRUE'

truecrypt_file = sys.argv[1]
password = "test"

decrypted_header = decrypt_truecrypt_header(truecrypt_file, password)

print("Header:")
print(hexdump(decrypted_header))
#print(hex(binascii.crc32(decrypted_header[192:447])))
print()

#polynom = 0x04C11DB7
#polynom = 0xEDB88320
#crc_truecrypt = crcmod.mkCrcFun(poly=polynom, initCrc=0xFFFFFFFF, xorOut=0xFFFFFFFF, rev=True)
#crc_truecrypt = crcmod.mkCrcFun(poly=polynom, initCrc=0xFFFFFFFF, xorOut=0xFFFFFFFF, rev=False)

print(hexdump(decrypted_header[0:188]))
print()
print(hexdump(decrypted_header[192:]))
print()
print(hexdump(decrypted_header[0:188]))
print()
print(hex(binascii.crc32(decrypted_header[192:])))
print(hex(binascii.crc32(decrypted_header[0:188])))
#print(hex(crc_truecrypt(decrypted_header[256:512])))

#if is_valid_truecrypt_header(decrypted_header):
#    print("Header:")
#    print(hexdump(decrypted_header))
#else:
#    print("Signature not found.")
