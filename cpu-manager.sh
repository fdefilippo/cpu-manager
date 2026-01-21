#!/bin/bash
# Script Name: cpu-manager.sh
# Description: Dynamic CPU management with cgroups v2 - Production version
# Version: 6.0 - Config file + Prometheus metrics
# License: MIT

# set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# DEFAULTS (overridable by config file and environment)
# ==============================================================================

# Paths
: "${CGROUP_ROOT:=/sys/fs/cgroup}"
: "${SCRIPT_CGROUP_BASE:=cpu_manager}"
: "${CONFIG_FILE:=/etc/cpu-manager.conf}"
: "${LOG_FILE:=/var/log/cpu-manager.log}"
: "${CREATED_CGROUPS_FILE:=/var/run/cpu-manager-cgroups.txt}"
: "${METRICS_CACHE_FILE:=/var/run/cpu-manager-metrics.cache}"
: "${PROMETHEUS_FILE:=/var/run/cpu-manager-metrics.prom}"

# Timing
: "${POLLING_INTERVAL:=30}"
: "${MIN_ACTIVE_TIME:=60}"
: "${METRICS_CACHE_TTL:=15}"

# Thresholds (percentages)
: "${CPU_THRESHOLD:=75}"
: "${CPU_RELEASE_THRESHOLD:=40}"

# CPU limits (cpu.max format: "quota period")
: "${CPU_QUOTA_NORMAL:=max 100000}"
: "${CPU_QUOTA_LIMITED:=50000 100000}"  # 0.5 core

# Prometheus
: "${ENABLE_PROMETHEUS:=false}"
: "${PROMETHEUS_PORT:=9101}"
: "${PROMETHEUS_HOST:=127.0.0.1}"

# Logging
: "${LOG_LEVEL:=INFO}"  # DEBUG, INFO, WARN, ERROR
: "${LOG_MAX_SIZE:=10485760}"  # 10MB

# System
: "${MIN_SYSTEM_CORES:=1}"
: "${SYSTEM_UID_MIN:=1000}"
: "${SYSTEM_UID_MAX:=$(cat /proc/sys/kernel/pid_max)}"

# State
LIMITS_ACTIVE=false
LIMITS_APPLIED_TIME=0
SCRIPT_PID=$$
PROMETHEUS_PID=0

# ==============================================================================
# CONFIGURATION LOADING
# ==============================================================================

load_config() {
    # Load from config file if exists
    if [[ -f "$CONFIG_FILE" ]]; then
        log "INFO" "Loading configuration from $CONFIG_FILE"
        
        # Use safe sourcing
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            
            # Clean key and value
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')
            
            # Skip if key is empty after cleaning
            [[ -z "$key" ]] && continue
            
            # Export as environment variable
            export "$key"="$value"
            log "DEBUG" "Config: $key=$value"
        done < "$CONFIG_FILE"
    fi
    
    # Validate critical values
    validate_config
}

validate_config() {
    local errors=()
    
    # Validate CPU thresholds
    if [[ "$CPU_THRESHOLD" -lt 1 || "$CPU_THRESHOLD" -gt 100 ]]; then
        errors+=("CPU_THRESHOLD must be between 1 and 100")
    fi
    
    if [[ "$CPU_RELEASE_THRESHOLD" -lt 1 || "$CPU_RELEASE_THRESHOLD" -gt 100 ]]; then
        errors+=("CPU_RELEASE_THRESHOLD must be between 1 and 100")
    fi
    
    if [[ "$CPU_THRESHOLD" -le "$CPU_RELEASE_THRESHOLD" ]]; then
        errors+=("CPU_THRESHOLD must be greater than CPU_RELEASE_THRESHOLD")
    fi
    
    # Validate polling interval
    if [[ "$POLLING_INTERVAL" -lt 5 ]]; then
        errors+=("POLLING_INTERVAL must be at least 5 seconds")
    fi
    
    # Validate CPU quota format
    if ! echo "$CPU_QUOTA_LIMITED" | grep -qE '^(max|[0-9]+) [0-9]+$'; then
        errors+=("CPU_QUOTA_LIMITED must be in format 'quota period' or 'max period'")
    fi
    
    # Validate log level
    if ! [[ "$LOG_LEVEL" =~ ^(DEBUG|INFO|WARN|ERROR)$ ]]; then
        errors+=("LOG_LEVEL must be one of: DEBUG, INFO, WARN, ERROR")
    fi
    
    # Validate UID ranges
    if [[ "$SYSTEM_UID_MIN" -lt 0 ]]; then
        errors+=("SYSTEM_UID_MIN cannot be negative")
    fi
    
    if [[ "$SYSTEM_UID_MAX" -lt "$SYSTEM_UID_MIN" ]]; then
        errors+=("SYSTEM_UID_MAX must be greater than SYSTEM_UID_MIN")
    fi
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        for err in "${errors[@]}"; do
            log "ERROR" "Configuration error: $err"
        done
        exit 1
    fi
    
    log "INFO" "Configuration validated successfully"
}

# ==============================================================================
# LOGGING SYSTEM
# ==============================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Check if we should log this level
    
    case "$LOG_LEVEL" in 
      DEBUG) [[ "$level" =~ ^(DEBUG|INFO|WARN|ERROR)$ ]] || return ;; 
      INFO) [[ "$level" =~ ^(INFO|WARN|ERROR)$ ]] || return ;; 
      WARN) [[ "$level" =~ ^(WARN|ERROR)$ ]] || return ;; 
      ERROR) [[ "$level" == "ERROR" ]] || return ;; 
      *) return ;; 
    esac

    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    
    # Rotate log if needed
    rotate_log
}

rotate_log() {
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $LOG_MAX_SIZE ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log "INFO" "Log rotated due to size limit"
    fi
}

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

clean_string() {
    echo "$1" | tr -d '[:space:]' | tr -cd '0-9'
}

is_valid_user_uid() {
    local uid="$1"
    [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$uid" -ge "$SYSTEM_UID_MIN" ]] && [[ "$uid" -le "$SYSTEM_UID_MAX" ]]
}

cleanup() {
    log "INFO" "=== CLEANUP STARTED ==="
    
    # Kill Prometheus server if running
    if [[ $PROMETHEUS_PID -gt 0 ]]; then
        log "INFO" "Stopping Prometheus exporter (PID: $PROMETHEUS_PID)"
        kill $PROMETHEUS_PID 2>/dev/null || true
    fi
    
    # Remove cgroups
    if [[ -f "$CREATED_CGROUPS_FILE" ]]; then
        while IFS= read -r cgroup_path; do
            [[ -z "$cgroup_path" ]] && continue
            
            if [[ -d "$cgroup_path" ]]; then
                log "DEBUG" "Cleaning cgroup: $cgroup_path"
                
                # Move processes to root
                if [[ -f "$cgroup_path/cgroup.procs" ]]; then
                    while IFS= read -r pid; do
                        pid=$(clean_string "$pid")
                        [[ -n "$pid" ]] && echo "$pid" > "$CGROUP_ROOT/cgroup.procs" 2>/dev/null || true
                    done < "$cgroup_path/cgroup.procs"
                    sleep 0.1
                fi
                
                # Remove cgroup
                rmdir "$cgroup_path" 2>/dev/null && log "DEBUG" "Removed: $cgroup_path"
            fi
        done < "$CREATED_CGROUPS_FILE"
        rm -f "$CREATED_CGROUPS_FILE"
    fi
    
    # Remove base cgroup
    if [[ -d "$CGROUP_ROOT/$SCRIPT_CGROUP_BASE" ]]; then
        find "$CGROUP_ROOT/$SCRIPT_CGROUP_BASE" -mindepth 1 -maxdepth 1 -type d -name "user_*" -exec rmdir {} \; 2>/dev/null || true
        rmdir "$CGROUP_ROOT/$SCRIPT_CGROUP_BASE" 2>/dev/null || true
    fi
    
    # Clean cache files
    rm -f "$METRICS_CACHE_FILE" "$PROMETHEUS_FILE"
    
    log "INFO" "=== CLEANUP COMPLETED ==="
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# ==============================================================================
# SYSTEM METRICS
# ==============================================================================

get_total_cores() {
    nproc
}

get_cpu_usage_real() {
    if command -v mpstat >/dev/null 2>&1; then
        mpstat 1 1 | awk '/Average:/ {print 100 - $NF}'
    elif command -v top >/dev/null 2>&1; then
        top -bn1 | grep "%Cpu(s)" | awk '{print 100 - $8}' | cut -d. -f1
    else
        # Fallback to /proc/stat
        local idle1 idle2 total1 total2
        
        read -r cpu user nice sys idle iowait irq softirq steal guest guest_nice <<< "$(grep '^cpu ' /proc/stat)"
        total1=$((user + nice + sys + idle + iowait + irq + softirq + steal + guest + guest_nice))
        idle1=$idle
        
        sleep 0.5
        
        read -r cpu user nice sys idle iowait irq softirq steal guest guest_nice <<< "$(grep '^cpu ' /proc/stat)"
        total2=$((user + nice + sys + idle + iowait + irq + softirq + steal + guest + guest_nice))
        idle2=$idle
        
        local total_delta=$((total2 - total1))
        local idle_delta=$((idle2 - idle1))
        
        if [[ $total_delta -gt 0 ]]; then
            echo $(( (total_delta - idle_delta) * 100 / total_delta ))
        else
            echo "0"
        fi
    fi
}

get_user_cpu_usage() {
    local uid="$1"
    uid=$(clean_string "$uid")
    
    if ! is_valid_user_uid "$uid"; then
        echo "0"
        return 0
    fi
    
    # Cache this for performance
    local cache_key="cpu_usage_$uid"
    local cache_file="${METRICS_CACHE_FILE}.${cache_key}"
    local current_time
    current_time=$(date +%s)
    
    if [[ -f "$cache_file" ]] && \
       [[ $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) -gt $((current_time - METRICS_CACHE_TTL)) ]]; then
        cat "$cache_file"
        return 0
    fi
    
    local cpu_usage
    cpu_usage=$(ps -U "$uid" -o pcpu= 2>/dev/null | awk '{sum += $1} END {printf "%.1f", sum}' || echo "0")
    
    echo "$cpu_usage" > "$cache_file"
    echo "$cpu_usage"
}

get_total_user_cpu_usage() {
    local cache_key="total_cpu_usage"
    local cache_file="${METRICS_CACHE_FILE}.${cache_key}"
    local current_time
    current_time=$(date +%s)
    
    if [[ -f "$cache_file" ]] && \
       [[ $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) -gt $((current_time - METRICS_CACHE_TTL)) ]]; then
        cat "$cache_file"
        return 0
    fi
    
    local total_cpu
    total_cpu=$(ps -eo uid,pcpu= 2>/dev/null | \
        awk -v min="$SYSTEM_UID_MIN" -v max="$SYSTEM_UID_MAX" \
        '$1 >= min && $1 <= max {sum += $2} END {printf "%.1f", sum}')
    
    echo "$total_cpu" > "$cache_file"
    echo "$total_cpu"
}

get_active_users() {
    local cache_key="active_users"
    local cache_file="${METRICS_CACHE_FILE}.${cache_key}"
    local current_time
    current_time=$(date +%s)
    
    if [[ -f "$cache_file" ]] && \
       [[ $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) -gt $((current_time - METRICS_CACHE_TTL)) ]]; then
        cat "$cache_file"
        return 0
    fi
    
    ps -eo uid= --no-headers 2>/dev/null | \
        awk -v min="$SYSTEM_UID_MIN" -v max="$SYSTEM_UID_MAX" \
        '$1 >= min && $1 <= max {print $1}' | \
        sort -u > "$cache_file"
    
    cat "$cache_file"
}

get_memory_usage() {
    awk '/MemTotal:/ {total=$2} /MemAvailable:/ {avail=$2} END {printf "%.1f", (total-avail)/1024}' /proc/meminfo
}

is_system_under_load() {
    local load cores
    load=$(awk '{print $1}' /proc/loadavg)
    cores=$(get_total_cores)
    
    # Use awk with different variable name to avoid conflict
    if awk -v l="$load" -v c="$cores" 'BEGIN {exit (l > c * 0.7) ? 0 : 1}'; then
        echo "1"
    else
        echo "0"
    fi
}

# ==============================================================================
# PROMETHEUS METRICS
# ==============================================================================

start_prometheus_exporter() {
    if [[ "$ENABLE_PROMETHEUS" != "true" ]]; then
        return 0
    fi

    return 

    log "INFO" "Starting Prometheus exporter on ${PROMETHEUS_HOST}:${PROMETHEUS_PORT}"
    # Create a simple HTTP server that serves metrics
    (
        while true; do
            if [[ -f "$PROMETHEUS_FILE" ]]; then
                # Use netcat to serve the metrics file
                {
                    echo -e "HTTP/1.1 200 OK\r"
                    echo -e "Content-Type: text/plain; version=0.0.4\r"
                    echo -e "Connection: close\r"
                    echo -e "\r"
                    cat "$PROMETHEUS_FILE"
                } | nc -l -p "$PROMETHEUS_PORT" -q 1 -s "$PROMETHEUS_HOST" 2>/dev/null || sleep 1
            else
                sleep 1
            fi
        done
    ) &
    
    PROMETHEUS_PID=$!
    log "INFO" "Prometheus exporter started (PID: $PROMETHEUS_PID)"
}

export_prometheus_metrics() {
    if [[ "$ENABLE_PROMETHEUS" != "true" ]]; then
        return 0
    fi
    
    local timestamp
    timestamp=$(date +%s)
    
    # System metrics
    local system_cpu
    system_cpu=$(get_cpu_usage_real)
    local total_cpu
    total_cpu=$(get_total_user_cpu_usage)
    local memory_usage
    memory_usage=$(get_memory_usage)
    local load1 load5 load15
    read -r load1 load5 load15 _ <<< "$(cat /proc/loadavg)"
    local cores
    cores=$(get_total_cores)
    
    # Collect active users
    local active_users=()
    mapfile -t active_users < <(get_active_users)
    local user_count=${#active_users[@]}
    
    cat > "$PROMETHEUS_FILE" << EOF
# HELP cpu_manager_system_cpu_usage System CPU usage percentage
# TYPE cpu_manager_system_cpu_usage gauge
cpu_manager_system_cpu_usage $system_cpu

# HELP cpu_manager_user_cpu_usage Total user CPU usage percentage
# TYPE cpu_manager_user_cpu_usage gauge
cpu_manager_user_cpu_usage $total_cpu

# HELP cpu_manager_memory_usage Memory usage in MB
# TYPE cpu_manager_memory_usage gauge
cpu_manager_memory_usage $memory_usage

# HELP cpu_manager_load_average_1m 1-minute load average
# TYPE cpu_manager_load_average_1m gauge
cpu_manager_load_average_1m $load1

# HELP cpu_manager_load_average_5m 5-minute load average
# TYPE cpu_manager_load_average_5m gauge
cpu_manager_load_average_5m $load5

# HELP cpu_manager_load_average_15m 15-minute load average
# TYPE cpu_manager_load_average_15m gauge
cpu_manager_load_average_15m $load15

# HELP cpu_manager_cores_total Total CPU cores
# TYPE cpu_manager_cores_total gauge
cpu_manager_cores_total $cores

# HELP cpu_manager_active_users Number of active users
# TYPE cpu_manager_active_users gauge
cpu_manager_active_users $user_count

# HELP cpu_manager_limits_active Whether CPU limits are active (1) or not (0)
# TYPE cpu_manager_limits_active gauge
cpu_manager_limits_active $([[ "$LIMITS_ACTIVE" == "true" ]] && echo 1 || echo 0)

# HELP cpu_manager_limits_duration_seconds How long limits have been active
# TYPE cpu_manager_limits_duration_seconds gauge
cpu_manager_limits_duration_seconds $([[ "$LIMITS_ACTIVE" == "true" ]] && echo $(( $(date +%s) - LIMITS_APPLIED_TIME )) || echo 0)

# HELP cpu_manager_iteration_total Total number of iterations
# TYPE cpu_manager_iteration_total counter
cpu_manager_iteration_total $ITERATION_COUNT
EOF
    
    # Per-user metrics
    for uid in "${active_users[@]}"; do
        local cpu_usage
        cpu_usage=$(get_user_cpu_usage "$uid")
        
        cat >> "$PROMETHEUS_FILE" << EOF

# HELP cpu_manager_user_cpu_usage_per_user CPU usage per user
# TYPE cpu_manager_user_cpu_usage_per_user gauge
cpu_manager_user_cpu_usage_per_user{uid="$uid"} $cpu_usage
EOF
        
        # Cgroup metrics if limits are active
        local cgroup_path="$CGROUP_ROOT/$SCRIPT_CGROUP_BASE/user_$uid"
        if [[ -d "$cgroup_path" ]]; then
            local cpu_limit=""
            if [[ -f "$cgroup_path/cpu.max" ]]; then
                cpu_limit=$(cat "$cgroup_path/cpu.max")
            fi
            
            local process_count=0
            if [[ -f "$cgroup_path/cgroup.procs" ]]; then
                process_count=$(wc -l < "$cgroup_path/cgroup.procs" 2>/dev/null || echo 0)
            fi
            
            cat >> "$PROMETHEUS_FILE" << EOF

# HELP cpu_manager_user_cpu_limit CPU limit for user (quota)
# TYPE cpu_manager_user_cpu_limit gauge
cpu_manager_user_cpu_limit{uid="$uid"} $(echo "$cpu_limit" | awk '{if ($1 == "max") print 100000; else print $1}')

# HELP cpu_manager_user_processes Number of processes in user cgroup
# TYPE cpu_manager_user_processes gauge
cpu_manager_user_processes{uid="$uid"} $process_count
EOF
        fi
    done
    
    log "DEBUG" "Prometheus metrics exported"
}

# ==============================================================================
# CGROUP MANAGEMENT
# ==============================================================================

init_cgroup() {
    log "INFO" "Initializing cgroup hierarchy..."
    
    if [[ -f "$CGROUP_ROOT/cgroup.subtree_control" ]]; then
        if ! grep -q "cpu" "$CGROUP_ROOT/cgroup.subtree_control"; then
            echo "+cpu" >> "$CGROUP_ROOT/cgroup.subtree_control"
            log "INFO" "Enabled CPU controller"
        fi
    else
        log "ERROR" "cgroup.subtree_control not found"
        return 1
    fi
    
    if [[ ! -d "$CGROUP_ROOT/$SCRIPT_CGROUP_BASE" ]]; then
        if mkdir -p "$CGROUP_ROOT/$SCRIPT_CGROUP_BASE"; then
            echo "$CGROUP_ROOT/$SCRIPT_CGROUP_BASE" >> "$CREATED_CGROUPS_FILE"
            log "INFO" "Created base cgroup: $CGROUP_ROOT/$SCRIPT_CGROUP_BASE"
            
            if [[ -f "$CGROUP_ROOT/$SCRIPT_CGROUP_BASE/cgroup.subtree_control" ]]; then
                echo "+cpu" > "$CGROUP_ROOT/$SCRIPT_CGROUP_BASE/cgroup.subtree_control"
            fi
        else
            log "ERROR" "Failed to create base cgroup"
            return 1
        fi
    fi
    
    return 0
}

create_user_cgroup() {
    local uid="$1"
    uid=$(clean_string "$uid")
    
    if ! is_valid_user_uid "$uid"; then
        return 1
    fi
    
    local cgroup_path="$CGROUP_ROOT/$SCRIPT_CGROUP_BASE/user_$uid"
    
    if [[ ! -d "$cgroup_path" ]]; then
        if mkdir -p "$cgroup_path"; then
            echo "$cgroup_path" >> "$CREATED_CGROUPS_FILE"
            log "INFO" "Created cgroup for UID $uid"
            
            # Set default CPU limit
            echo "$CPU_QUOTA_NORMAL" > "$cgroup_path/cpu.max" 2>/dev/null || true
        else
            log "ERROR" "Failed to create cgroup for UID $uid"
            return 1
        fi
    fi
    
    return 0
}

apply_cpu_limit() {
    local uid="$1"
    local quota="$2"
    
    uid=$(clean_string "$uid")
    
    if ! is_valid_user_uid "$uid"; then
        return 0
    fi
    
    local cgroup_path="$CGROUP_ROOT/$SCRIPT_CGROUP_BASE/user_$uid"
    
    if [[ -f "$cgroup_path/cpu.max" ]]; then
        if echo "$quota" > "$cgroup_path/cpu.max" 2>/dev/null; then
            log "INFO" "Set CPU limit for UID $uid: $quota"
        else
            log "ERROR" "Failed to set CPU limit for UID $uid"
        fi
    fi
}

assign_processes() {
    local uid="$1"
    uid=$(clean_string "$uid")
    
    if ! is_valid_user_uid "$uid"; then
        return 0
    fi
    
    local cgroup_path="$CGROUP_ROOT/$SCRIPT_CGROUP_BASE/user_$uid"
    
    if [[ ! -d "$cgroup_path" ]]; then
        return 1
    fi
    
    local assigned=0
    local pids=()
    
    # Get PIDs for user
    mapfile -t pids < <(ps -U "$uid" -o pid= --no-headers 2>/dev/null | 
        awk '{print $1}' | 
        grep -E '^[0-9]+$')
    
    for pid in "${pids[@]}"; do
        if [[ ! -f "/proc/$pid/status" ]]; then
            continue
        fi
        
        local current_cgroup=""
        if [[ -f "/proc/$pid/cgroup" ]]; then
            current_cgroup=$(awk -F: '$2 ~ /cpu/ {print $3; exit}' "/proc/$pid/cgroup" 2>/dev/null || echo "")
        fi
        
        local target_cgroup="/$SCRIPT_CGROUP_BASE/user_$uid"
        
        if [[ "$current_cgroup" != "$target_cgroup" ]]; then
            if echo "$pid" > "$cgroup_path/cgroup.procs" 2>/dev/null; then
                ((assigned++))
            fi
        fi
    done
    
    if [[ -f "$cgroup_path/cgroup.procs" ]]; then
        local process_count
        process_count=$(wc -l < "$cgroup_path/cgroup.procs" 2>/dev/null || echo "0")
        log "DEBUG" "Processes in cgroup UID $uid: $process_count"
    fi
    
    if [[ $assigned -gt 0 ]]; then
        log "INFO" "Assigned $assigned new processes to UID $uid"
    fi
    
    return 0
}

# ==============================================================================
# LIMIT MANAGEMENT
# ==============================================================================

apply_limits() {
    log "INFO" "=== APPLYING CPU LIMITS ==="
    
    if ! init_cgroup; then
        log "ERROR" "Failed to initialize cgroups"
        return 1
    fi
    
    local users=()
    mapfile -t users < <(get_active_users)
    
    if [[ ${#users[@]} -eq 0 ]]; then
        log "INFO" "No active users found"
        return 0
    fi
    
    local total_cpu
    total_cpu=$(get_total_user_cpu_usage)
    
    if awk -v total="$total_cpu" -v threshold="$CPU_THRESHOLD" 'BEGIN {exit (total >= threshold) ? 0 : 1}' || \
       [[ "$(is_system_under_load)" -eq 1 ]]; then
        
        log "INFO" "Activating limits: user CPU=${total_cpu}% >= ${CPU_THRESHOLD}%"
        log "INFO" "Active users: ${#users[@]}"
        
        for uid in "${users[@]}"; do
            uid=$(clean_string "$uid")
            
            if ! is_valid_user_uid "$uid"; then
                continue
            fi
            
            log "INFO" "Processing UID $uid"
            
            if ! create_user_cgroup "$uid"; then
                continue
            fi
            
            # Apply CPU limit
            apply_cpu_limit "$uid" "$CPU_QUOTA_LIMITED"
            
            # Assign processes
            assign_processes "$uid"
            
            # Log current usage
            local current_usage
            current_usage=$(get_user_cpu_usage "$uid")
            log "INFO" "UID $uid CPU usage: ${current_usage}%"
        done
        
        LIMITS_ACTIVE=true
        LIMITS_APPLIED_TIME=$(date +%s)
        log "INFO" "CPU limits activated successfully"
        
    else
        log "INFO" "No activation needed: user CPU=${total_cpu}% < ${CPU_THRESHOLD}%"
    fi
}

remove_limits() {
    log "INFO" "=== REMOVING CPU LIMITS ==="
    
    if [[ -d "$CGROUP_ROOT/$SCRIPT_CGROUP_BASE" ]]; then
        for user_dir in "$CGROUP_ROOT/$SCRIPT_CGROUP_BASE"/user_*; do
            [[ -d "$user_dir" ]] || continue
            
            local uid
            uid=$(basename "$user_dir" | sed 's/user_//')
            uid=$(clean_string "$uid")
            
            if is_valid_user_uid "$uid"; then
                log "INFO" "Removing limits for UID $uid"
                
                # Restore unlimited CPU
                echo "$CPU_QUOTA_NORMAL" > "$user_dir/cpu.max" 2>/dev/null || true
                
                # Move processes to root (optional - can be commented out)
                if [[ -f "$user_dir/cgroup.procs" ]]; then
                    while IFS= read -r pid; do
                        pid=$(clean_string "$pid")
                        [[ -n "$pid" ]] && echo "$pid" > "$CGROUP_ROOT/cgroup.procs" 2>/dev/null || true
                    done < "$user_dir/cgroup.procs"
                fi
            fi
        done
    fi
    
    LIMITS_ACTIVE=false
    log "INFO" "CPU limits removed"
}

# ==============================================================================
# MAIN LOGIC
# ==============================================================================

manage_resources() {
    log "INFO" "----- Resource Check -----"
    
    local system_cpu user_cpu load1 cores under_load memory_usage
    system_cpu=$(get_cpu_usage_real)
    user_cpu=$(get_total_user_cpu_usage)
    load1=$(awk '{print $1}' /proc/loadavg)
    cores=$(get_total_cores)
    under_load=$(is_system_under_load)
    memory_usage=$(get_memory_usage)
    
    log "INFO" "System CPU: ${system_cpu}%"
    log "INFO" "User CPU: ${user_cpu}%"
    log "INFO" "Memory: ${memory_usage}MB"
    log "INFO" "Load (1m): $load1"
    log "INFO" "Cores: $cores"
    log "INFO" "Under load: $([ "$under_load" -eq 1 ] && echo "YES" || echo "NO")"
    
    # Export metrics
    export_prometheus_metrics
    
    # Decision logic
    if [[ "$LIMITS_ACTIVE" == "false" ]]; then
        if awk -v user="$user_cpu" -v threshold="$CPU_THRESHOLD" 'BEGIN {exit (user >= threshold) ? 0 : 1}' || \
           [[ "$under_load" -eq 1 ]]; then
            log "INFO" "Decision: ACTIVATE limits"
            apply_limits
        else
            log "INFO" "Decision: No action needed"
        fi
    else
        local current_time elapsed_time
        current_time=$(date +%s)
        elapsed_time=$((current_time - LIMITS_APPLIED_TIME))
        
        log "INFO" "Limits active for ${elapsed_time}s"
        
        # Reassign processes (for new forks)
        local users=()
        mapfile -t users < <(get_active_users)
        for uid in "${users[@]}"; do
            uid=$(clean_string "$uid")
            if is_valid_user_uid "$uid"; then
                assign_processes "$uid"
            fi
        done
        
        if [[ $elapsed_time -ge $MIN_ACTIVE_TIME ]]; then
            if awk -v user="$user_cpu" -v release="$CPU_RELEASE_THRESHOLD" 'BEGIN {exit (user < release) ? 0 : 1}' && \
               [[ "$under_load" -eq 0 ]]; then
                log "INFO" "Decision: REMOVE limits"
                remove_limits
            else
                log "INFO" "Decision: KEEP limits"
            fi
        else
            log "INFO" "Decision: KEEP limits (minimum time not reached)"
        fi
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    # Load configuration
    load_config
    
    # Create necessary directories
    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$CREATED_CGROUPS_FILE")"
    
    # Initialize log
    log "INFO" "========================================"
    log "INFO" "CPU Manager v6.0 - Starting"
    log "INFO" "========================================"
    log "INFO" "PID: $$"
    log "INFO" "Configuration:"
    log "INFO" "  Config file: $CONFIG_FILE"
    log "INFO" "  Log file: $LOG_FILE"
    log "INFO" "  Polling interval: ${POLLING_INTERVAL}s"
    log "INFO" "  CPU threshold: ${CPU_THRESHOLD}%"
    log "INFO" "  CPU release threshold: ${CPU_RELEASE_THRESHOLD}%"
    log "INFO" "  CPU limit: $CPU_QUOTA_LIMITED"
    log "INFO" "  Log level: $LOG_LEVEL"
    log "INFO" "  Prometheus: $([ "$ENABLE_PROMETHEUS" == "true" ] && echo "Enabled on port $PROMETHEUS_PORT" || echo "Disabled")"
    
    # Check requirements
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Root privileges required"
        exit 1
    fi
    
    if ! grep -q "cgroup2" /proc/mounts; then
        log "ERROR" "cgroups v2 not mounted"
        exit 1
    fi
    
    # Initialize files
    > "$CREATED_CGROUPS_FILE"
    
    # Start Prometheus exporter if enabled
    start_prometheus_exporter
    
    log "INFO" "System verified. Starting monitoring..."
    
    # Main loop
    ITERATION_COUNT=0
    while true; do
        ((ITERATION_COUNT++))
        log "INFO" ""
        log "INFO" "===== Iteration #$ITERATION_COUNT ====="
        
        manage_resources
        
        log "INFO" "Waiting for next check (${POLLING_INTERVAL}s)..."
        sleep "$POLLING_INTERVAL"
    done
}

main "$@"
