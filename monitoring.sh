#!/bin/bash  

src=/etc/webhook/source
dest=/etc/webhook

cat $src/* | jq -s add > $dest/hooks.json 

inotifywait -mrq -e modify,delete,create,attrib $src |  while read file 
do  
      cat $src/* | jq -s add > $dest/hooks.json 
done
