# DataMirror Server Setup Guide

Production-ready structure for running DataMirror extractions on secure server.

## Recommended Directory Structure

```
~/datamirror/
├── data/                          # Input data (read-only)
│   ├── population/
│   ├── income/
│   └── education/
│
├── checkpoints/                   # Output checkpoint files
│   ├── YYYY-MM-DD_HHMM/          # Timestamped extraction runs
│   │   ├── population__*.dta/
│   │   ├── income__*.dta/
│   │   └── extraction.log
│   └── latest -> YYYY-MM-DD_HHMM # Symlink to most recent
│
├── logs/                          # All log files
│   ├── extraction_YYYYMMDD_HHMM.log
│   ├── batch_YYYYMMDD_HHMM.log
│   └── errors_YYYYMMDD_HHMM.log
│
├── scripts/                       # Production scripts
│   ├── extract_all.do            # Main extraction script
│   ├── extract_one.do            # Single dataset extraction
│   ├── verify_privacy.do         # Privacy audit
│   └── config.do                 # Global settings
│
├── tmp/                          # Temporary files
│   └── .gitignore               # Don't commit temp files
│
├── archive/                      # Old extractions
│   └── YYYY-MM-DD_HHMM/
│
└── README.md                     # Documentation
```

## Setup Script

Save as `~/setup_datamirror_server.sh`:

```bash
#!/bin/bash
# DataMirror Server Setup
# Run once: bash setup_datamirror_server.sh

echo "Setting up DataMirror production environment..."

# Create directory structure
cd ~
mkdir -p datamirror/{data,checkpoints,logs,scripts,tmp,archive}

# Create .gitignore for tmp/
cat > datamirror/tmp/.gitignore <<'EOF'
*
!.gitignore
EOF

# Create README
cat > datamirror/README.md <<'EOF'
# DataMirror Production Environment

## Quick Start

Start extraction in tmux:
```bash
tmux new -s datamirror
cd ~/datamirror
stata -b do scripts/extract_all.do
# Detach: Ctrl+b, d
```

Monitor progress:
```bash
tmux attach -t datamirror
# Or
tail -f logs/extraction_*.log
```

## Directory Structure

- `data/` - Input datasets (read-only)
- `checkpoints/` - Output checkpoint files (timestamped)
- `logs/` - All log files
- `scripts/` - Production scripts
- `tmp/` - Temporary working directory
- `archive/` - Old extractions

## Privacy Settings

Current: `DM_MIN_CELL_SIZE = 50` (maximum safety)

See: https://github.com/your-org/datamirror/docs/PRIVACY.md
EOF

echo ""
echo "✓ Directory structure created in ~/datamirror/"
echo ""
echo "Next steps:"
echo "  1. Move data files to ~/datamirror/data/"
echo "  2. Copy scripts to ~/datamirror/scripts/"
echo "  3. Run: cd ~/datamirror && stata -b do scripts/extract_all.do"
