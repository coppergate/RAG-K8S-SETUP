#!/bin/bash
# setup-junie-user.sh

# 1. Ensure the 'super-user' group exists
if ! getent group super-user > /dev/null; then
    echo "Creating 'super-user' group..."
    sudo groupadd super-user
fi

# 2. Create the 'junie' user
if ! id "junie" &>/dev/null; then
    echo "Creating 'junie' user..."
    sudo useradd -m -s /bin/bash -g super-user junie
else
    echo "User 'junie' already exists. Updating group..."
    sudo usermod -g super-user junie
fi

# 3. Setup SSH directory
JUNIE_HOME="/home/junie"
sudo mkdir -p "${JUNIE_HOME}/.ssh"
sudo chmod 700 "${JUNIE_HOME}/.ssh"

# 4. Generate SSH Key Pair (as 'junie' to avoid permission issues)
# We generate them in a temp location first
TEMP_KEY="/tmp/junie_id_ed25519"
sudo -u junie ssh-keygen -t ed25519 -f "$TEMP_KEY" -N "" -C "junie@agent"

# 5. Authorize the public key
sudo -u junie bash -c "cat ${TEMP_KEY}.pub >> ${JUNIE_HOME}/.ssh/authorized_keys"
sudo chmod 600 "${JUNIE_HOME}/.ssh/authorized_keys"
sudo chown -R junie:super-user "${JUNIE_HOME}/.ssh"

# 6. Display the Private Key for the Agent
echo "========================================================================"
echo "FINISHED: User 'junie' is set up."
echo "========================================================================"
echo "COPY THE CONTENT BELOW (INCLUDING THE BEGIN/END LINES) AND PASTE TO CHAT:"
echo ""
sudo cat "$TEMP_KEY"
echo ""
echo "========================================================================"

# Cleanup the temp private key file after displaying
sudo rm "$TEMP_KEY"
sudo rm "${TEMP_KEY}.pub"