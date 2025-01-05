import hashlib

def hmac_sha512(key, salt, iterations):
    block_size = 128

    if len(key) > block_size:
        key = hashlib.sha512(key).digest()

    key += b'\x00' * (block_size - len(key))

    hmac = key
    postfix = salt + (1).to_bytes(4)
    rkey = b'\x00' * block_size
    for i in range(0, iterations):
        inner = hashlib.sha512(bytes([x ^ 0x36 for x in key]) + postfix).digest()
        hmac = hashlib.sha512(bytes([x ^ 0x5c for x in key]) + inner).digest()
        postfix = hmac
        rkey = bytes([x ^ y for x, y in zip(rkey, hmac)])
        #print('m', hmac.hex(), rkey.hex())

    return rkey.hex()

key = b"mein_geheimer_schlssel"
message = b"Dies ist eine Nachricht"
key = b'test'
message = b'test'

#iterations = 2000
iterations = 1
hmac_result = hmac_sha512(key, message, iterations)
print(hmac_result)
print(hashlib.pbkdf2_hmac('sha-512', key, message, iterations).hex())
