#
# !/usr/bin/env bash
# analysis_script.sh
#
#
# create shell sript that reads the log file and provides following information
#
#   Top 5 IP addresses with the most requests
#   Top 5 most requested paths
#   Top 5 response status codes
#   Top 5 user agents
#
#
#
#
#


#search through file for IP address with most reqs
#filter to find the ip addresses that appear the most times
#output format 
# ip address - x requests

set -euo pipefail

#helper function that prints usage instructions and exits
#$0 is the script name itself
usage() {
    echo "Usage: $0 <access.log | access.log.gz | ->"
    echo " Pass '-' to read from stdin."
    exit 1
}

#checks if exactly one argument was passed $= the number of args
#if not exactly one argument, then we call usage
# $1 = the first arg, access log, stored in INPUT
[[ $# -ne 1 ]] && usage
INPUT="$1"


#function for how we read the log file
# if argument is '-' -> read from stdin (cat -)
# if file ends with .gz -> its compressed so use gzip -dc to decompress
#   -d for decompress, -c write to stdout, otherwise we just cat the file
read_stream() {
  local f="$1"
  if [[ "$f" == "-" ]]; then
    cat -
  elif [[ "$f" == *.gz ]]; then
    gzip -dc -- "$f"
  else
    cat -- "$f"
  fi
}

# reads the file/stream in the right way
# $1 -> first field of each log line (the client ip)
#if ip is not '-', increment count for the ip (cnt[ip]++)
# END -> print each ip and its count
# %40s -> left align IP in a 40 character field
# %d -> the count
read_stream "$INPUT"  |
  awk '{ ip=$1; if (ip != "-") cnt[ip]++ }  
       END {for (i in cnt) printf "%-40s %d\n", i, cnt[i]}' |
  sort -k2,2nr |
  head -n 5
echo "-------"

#using same method above for accessing url path and its frequency
#$7 is the request path in the nginx-access.log
#sort -k2,2nr \ sort by 2nd column (count), numeric (n), descending(r)
read_stream "$INPUT" |
awk '
    { path=$7; if (path != "-") cnt[path]++ } 
    END {for (i in cnt) printf "%-40s %d\n", i,cnt[i] }' |
sort -k2,2nr |
head -n 5
echo "-------"

#access top 5 response status codes

#NF is built-in awk var (num fields in current line)
#which is how may whitespace seperated columns it has 
#NF >= 9 means only process lines that have atleast 9 fields, this guards against blank
#lines or corrupted lines
#status=$9, 9th field in the log line

#if statement -> ~ is regex match op
#/^[0-9]{3}$/ matches any 3 digit number like 200,404,500
#so basical;y is the field looks like a status code, increment a counter
#and cnt[status]++ means add 1 to the bucket for this status code

#END block runs once after all lines are processed
#for loop, loops over all status codes seen
#%-8s -> left aligned string, width 8 (the status code)
# %d -> integer (the count)
read_stream "$INPUT" |
awk '
    NF >=9 {
        status = $9
        if (status ~ /^[0-9]{3}$/) cnt[status]++
    }
    END {
        for (s in cnt) printf "%-8s %d\n", s,cnt[s]
    }
'|
sort -k2,2nr |
head -n 5
echo "---------"






read_stream "$INPUT" |
awk -F\" '
  {
    # (1) If the file was saved with Windows line endings, strip trailing \r
    sub(/\r$/, "", $0)

    # (2) We split on double quotes: -F\" makes " the field separator.
    #     In Nginx combined logs, quoted fields are:
    #       $2 = "GET /path HTTP/1.1"
    #       $4 = "referer"
    #       $6 = "user-agent"
    #     Using NF (number of fields), the penultimate quoted field (NF-1)
    #     is the user agent reliably, even if there are spaces inside it.
    if (NF >= 6) {
      ua = $(NF-1)
      if (ua != "-" && ua != "") cnt[ua]++
    }
  }
  END {
    for (ua in cnt) {
      printf "%-60s %d\n", ua, cnt[ua]
    }
  }
' |
sort -k2,2nr |
head -n 5
echo "---------"




