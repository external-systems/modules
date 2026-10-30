# --- Color Definitions ---
RESET='\e[0m'
BOLD='\e[1m'

# Regular Colors
YELLOW='\e[0;33m'
CYAN='\e[0;36m'
WHITE='\e[0;37m'

# Header for system info
echo -e "${BOLD}${WHITE}  #-- ${USER}@${HOSTNAME} --#  ${RESET}"

# System Load
load=$(cut -d' ' -f1 /proc/loadavg)
printf "%-18s: $BOLD$YELLOW%s$RESET\n" "System Load" "$load"

# Memory Usage
mem_usage=$(free -m | awk 'NR==2 {printf "%.0f%%", $3*100/$2 }')
printf "%-18s: $BOLD$CYAN%s$RESET\n" "Memory Usage" "$mem_usage"
