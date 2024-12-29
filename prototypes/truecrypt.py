import sys
import os
from hashlib import pbkdf2_hmac
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

def hexdump(data, length=16):
    result = []
    for i in range(0, len(data), length):
        chunk = data[i:i+length]
        hex_part = ' '.join(f'{byte:02x}' for byte in chunk)
        ascii_part = ''.join((chr(byte) if 32 <= byte <= 126 else '.') for byte in chunk)
        result.append(f'{i:08x}  {hex_part:<{length*3}}  {ascii_part}')
    return '\n'.join(result)

def get_cipher(password, salt):
    key = pbkdf2_hmac('ripemd160', password.encode(), salt, 2000, 64)
    iv = b'\x00' * 16
    return Cipher(algorithms.AES(key), modes.XTS(iv), backend=default_backend())

def decrypt_truecrypt_header(file_path, password):
    with open(file_path, "rb") as f:
        data = f.read(512)

    old_salt = data[0:64]
    encrypted_header = data[64:]

    xts_cipher = get_cipher(password, old_salt)
    cipher = xts_cipher.decryptor()
    decrypted_header = cipher.update(encrypted_header) + cipher.finalize()

    return decrypted_header, old_salt

def encrypt_truecrypt_header(header, password, new_salt):
    xts_cipher = get_cipher(password, new_salt)
    cipher = xts_cipher.encryptor()
    encrypted_header = cipher.update(header) + cipher.finalize()

    return encrypted_header

def write_new_header(file_path, new_salt, new_encrypted_header):
    with open(file_path, "r+b") as f:
        f.seek(0)  # Rewind to the start of the file
        f.write(new_salt + new_encrypted_header)

truecrypt_file = sys.argv[1]
password = "test"

# Decrypt the existing header
decrypted_header, old_salt = decrypt_truecrypt_header(truecrypt_file, password)

print(hexdump(decrypted_header))

# Generate a new salt
#new_salt = os.urandom(64)

# Encrypt the header with the new salt
#new_encrypted_header = encrypt_truecrypt_header(decrypted_header, password, new_salt)

# Write the new salt and new encrypted header back to the file
#write_new_header(truecrypt_file, new_salt, new_encrypted_header)

#print("New header written with the following salt:")
#print(hexdump(new_salt))
