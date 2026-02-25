# Oracle RMAN Backup Strategy

## Prerequisites

### Control File Retention
Set the control file record keep time to match your retention needs.
> ⚠️ If you need very long retention, consider using a **Recovery Catalog** instead.
```sql
ALTER SYSTEM SET control_file_record_keep_time=100 SCOPE=BOTH;
```

---

## Setup

### 1. Create Directory Structure & Scripts

Switch to the oracle user and create the config folder:
```bash
sudo su - oracle
mkdir -p /home/oracle/scripts/config/
```

Populate the required files with their respective contents:
```bash
vi /home/oracle/scripts/config/mydb.cfg
vi /home/oracle/scripts/rman_backup_hybrid.sh
vi /home/oracle/scripts/rman_arch_backup.sh
```

### 2. Set Execute Permissions
```bash
chmod +x rman_backup_hybrid.sh
chmod +x rman_arch_backup.sh
```

---

## Crontab Configuration

Edit crontab (`crontab -e`) and add the following entries:

### 1. Main Backup
Runs daily at **19:30**:
```
30 19 * * * /home/oracle/scripts/rman_backup_hybrid.sh /home/oracle/scripts/config/MYDB.cfg
```

### 2. Archivelog Backup
Runs **every hour at :20**:
```
20 * * * * /home/oracle/scripts/rman_arch_backup.sh /home/oracle/scripts/config/MYDB.cfg
```

---

## Testing (Optional)

Verify the scripts are working correctly by running them manually in the background:
```bash
# Test Main Backup
nohup /home/oracle/scripts/rman_backup_hybrid.sh /home/oracle/scripts/config/MYDB.cfg \
  > /tmp/nohup_hybrid_manual.out 2>&1 &

# Test Archivelog Backup
nohup /home/oracle/scripts/rman_arch_backup.sh /home/oracle/scripts/config/MYDB.cfg \
  > /tmp/nohup_arch_manual.out 2>&1 &
```

Check the output logs at:
- `/tmp/nohup_hybrid_manual.out`
- `/tmp/nohup_arch_manual.out`
