# Crucible – Quick Install

Use one of the following methods to download and run the installer. The script will prompt before installing gum and then launch the startup menu.

## Option A: wget
```bash
wget -O install.sh https://raw.githubusercontent.com/ekrist1/gumcrucible/main/install.sh
chmod +x install.sh
./install.sh
```

## Option B: curl
```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/ekrist1/gumcrucible/main/install.sh
chmod +x install.sh
./install.sh
```

## Optional one-liners (piped)
Note: These may not work in strictly non-interactive contexts due to the confirmation prompt.
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ekrist1/gumcrucible/main/install.sh)"
# or
curl -fsSL https://raw.githubusercontent.com/ekrist1/gumcrucible/main/install.sh | bash
# or
wget -qO- https://raw.githubusercontent.com/ekrist1/gumcrucible/main/install.sh | bash
```
