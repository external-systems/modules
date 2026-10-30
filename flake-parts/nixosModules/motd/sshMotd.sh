# --- Color Definitions ---
RESET='\e[0m'
BOLD='\e[1m'

# Regular Colors
GREEN='\e[0;32m'
YELLOW='\e[0;33m'
MAGENTA='\e[0;35m'
CYAN='\e[0;36m'
WHITE='\e[0;37m'

# --- MOTD SCRIPT --- #

echo -e "Welcome $BOLD$MAGENTA$USER$RESET to$BOLD$CYAN $HOSTNAME$RESET 👋"

# Header for system info
echo -e "${BOLD}${WHITE}  #-- System Information --#  ${RESET}"

# System Load
load=$(cut -d' ' -f1 /proc/loadavg)
printf "%-18s: ${BOLD}${YELLOW}%s${RESET}\n" "System Load" "$load"

# Memory Usage
mem_usage=$(free -m | awk 'NR==2 {printf "%.0f%%", $3*100/$2 }')
printf "%-18s: ${BOLD}${CYAN}%s${RESET}\n" "Memory Usage" "$mem_usage"

# Logged in Users
users_logged_in=$(who | wc -l)
printf "%-18s: ${BOLD}${MAGENTA}%s${RESET}\n" "Users Logged In" "$users_logged_in"

# Disk Usage /boot
disk_boot_usage=$(df -h /boot | awk 'NR==2 {print $5 " of " $2}')
printf "%-18s: ${BOLD}${GREEN}%s${RESET}\n" "/boot" "$disk_boot_usage"

# Disk Usage /
disk_root_usage=$(df -h / | awk 'NR==2 {print $5 " of " $2}')
printf "%-18s: ${BOLD}${GREEN}%s${RESET}\n" "/" "$disk_root_usage"
