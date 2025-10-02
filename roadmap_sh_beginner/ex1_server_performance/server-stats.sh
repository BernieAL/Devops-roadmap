
#!/bin/bash


LOGFILE="system_report.log"

#LOOK AT CPU USAGE
#-b means batch mode, no interactive UI
#n1 means one iteration
#subtract id from 100 to get total CPU USAGE
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print  100 - $8"%"}')


#look at total mem usage
FREE_MEM_USAGE=$(free -m)

#look at disk usage
TOTAL_DISK_USAGE=$(df -h --total)

#look at top 5 processes by cpu usage
#e -> all processes
#-o -> custom output (pid,command,CPU,mem)
#head -n 6 -> top 5 plus header
CPU_USG=$(ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 6)

#look at top 5 processes by mem usage
MEM_USG=$(ps -eo pid,comm,%mem --sort=-%mem | head -n 6)

#write to file
{
  echo "===== System Report: $(date) ====="
  echo "CPU Usage: $CPU_USAGE"
  echo "Memory Usage: $MEM_USAGE"
  echo "Disk Usage: $DISK_USAGE"
  echo
  echo "Top 5 Processes by CPU:"
  echo "$CPU_USG"
  echo
  echo "Top 5 Processes by Memory:"
  echo "$MEM_USG"
  echo "==================================="
  echo
} >> "$LOGFILE"