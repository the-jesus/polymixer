#!/usr/bin/python3.6

# make poly mp3

import requests
import shutil
import FileHandler

from mutagen.id3 import ID3, TIT2, APIC


srcfile 	= 'song.mp3'
payfile 	= 'container.vc'
trgfile 	= 'song-poly.mp3'
salt    	= 'salt'

with open('train_example.bson', 'rb') as src:
    # fbson.seek(file_pointers[1])
    bytes_chunk = src.read(64)
    with open(trgfile, 'wb') as trg:
        trg.write(bytes_chunk)

def addMetaData(url, title, artist, album, track):

    response = requests.get(url, stream=True)
    with open(payfile, 'wb') as out_file:
        shutil.copyfileobj(response.raw, out_file)
    del response

    audio = ID3(srcfile)
    audio['TIT2'] = TALB(encoding=3, text=title)

    with open('container', 'rb') as albumart:
        audio['APIC'] = APIC(
                          encoding=0,
                          mime='0',
                          type=0, desc=u'0',
                          data=albumart.read()
                        )            
    audio.save()

print ( ' --text ', '-v',  ' --change='+ trgfile , '--password=test ','-k "" ','--pim=0 ', '--random-source /etc/products.d/baseproduct ','--new-password=test ','--new-pim=0 ', '--new-keyfiles "" ', '--extsalt='+ salt, '--verbose')
subprocess.run(['./veracrypt', ' --text ', '-v', ' --change=poly.png' , '--password=test ','--keyfiles=none ','--pim=0', '--random-source /etc/products.d/baseproduct ','--new-password=test ','--new-pim=0 ', '--new-keyfiles', '--extsalt saltfile' ]) 
#subprocess.run(['./resalt.sh', trgfile ,  salt] ) 
print ('done')
             
exit()