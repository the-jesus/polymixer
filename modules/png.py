#!/usr/bin/python3.6

# make poly png

import struct
import binascii
import subprocess
import random
import string

srcfile 	= 'bild.png'
payfile 	= 'container.vc'
trgfile 	= 'poly.png'
salt    	= 'salt'
z 		= struct.Struct('4s')
fake_header 	= b'fRAc'
random.seed(10)


png = open(srcfile,'rb').read()
chunk_data = open(payfile,'rb').read()
bytecount = 8 

# png header to target & salt
f = open(trgfile,'wb')
s = open(salt,'wb')
f.write(chunk_data)
s.write(png[0:bytecount])

while bytecount<len(png):
    bak_len = bytecount

    # read chunk
    length,header = struct.unpack('>I4s',png[bytecount:bytecount+8])
    bytecount +=8
    data = png[bytecount:bytecount+length]
    bytecount +=length
    crc = png[bytecount:bytecount+4]
    bytecount +=4

    calc_crc = struct.pack('>I',binascii.crc32(header+data) & 0xffffffff)

    # write out header
    if(header==b'IHDR'):
         chunk_length = struct.pack('>I',len(chunk_data))
         fake_header = struct.pack('%ds'%(len(fake_header)), fake_header )
         checksum = binascii.crc32(fake_header+chunk_data) & 0xffffffff
         checksum_hex = struct.pack('>I',checksum)
         f.write(checksum_hex)
         s.write(chunk_length + fake_header + bytes(''.join(random.sample(string.ascii_letters+string.digits, 64- len(fake_header + chunk_length)-8 )),'utf-8'))
    else:
         f.write(png[bak_len:bytecount])

print ( ' --text ', '-v',  ' --change='+ trgfile , '--password=test ','-k "" ','--pim=0 ', '--random-source /etc/products.d/baseproduct ','--new-password=test ','--new-pim=0 ', '--new-keyfiles "" ', '--extsalt='+ salt, '--verbose')
subprocess.run(['./veracrypt', ' --text ', '-v', ' --change=poly.png' , '--password=test ','--keyfiles=none ','--pim=0', '--random-source /etc/products.d/baseproduct ','--new-password=test ','--new-pim=0 ', '--new-keyfiles', '--extsalt saltfile' ]) 
#subprocess.run(['./resalt.sh', trgfile ,  salt] ) 
print ('done')
             
