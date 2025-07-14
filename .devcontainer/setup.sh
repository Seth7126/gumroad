#!/bin/bash
set -euxo pipefail # 开启严格的调试模式

# --- 脚本自我检查 ---
if ! grep -q "Debian" /etc/os-release; then
    echo "错误：此脚本专为 Debian 环境设计！当前环境不匹配。"
    exit 1
fi

echo "--- 开始环境设置 (Debian Bullseye) ---"

# --- 步骤 1/7: 安装系统依赖 ---
echo "--- 步骤 1/7: 安装系统依赖 ---"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    imagemagick libvips-dev ffmpeg pdftk libnss3-tools curl unzip default-jre gnupg

# --- 步骤 2/7: 安装 Percona Toolkit ---
echo "--- 步骤 2/7: 安装 Percona Toolkit ---"
wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
sudo dpkg -i percona-release_latest.generic_all.deb
sudo percona-release setup ps80 -y
sudo apt-get update
sudo apt-get install -y percona-toolkit
rm percona-release_latest.generic_all.deb

# --- 步骤 3/7: 安装 Elasticsearch ---
echo "--- 步骤 3/7: 安装 Elasticsearch ---"
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-7.x.list
sudo apt-get update
sudo apt-get install -y elasticsearch
echo "discovery.type: single-node" | sudo tee -a /etc/elasticsearch/elasticsearch.yml > /dev/null
echo "-Xms512m" | sudo tee /etc/elasticsearch/jvm.options.d/jvm-memory.options > /dev/null
echo "-Xmx512m" | sudo tee -a /etc/elasticsearch/jvm.options.d/jvm-memory.options > /dev/null
echo '#!/bin/bash
sudo service elasticsearch start' | sudo tee /usr/local/bin/start-es > /dev/null
sudo chmod +x /usr/local/bin/start-es

# --- 步骤 4/7: 安装 mkcert ---
echo "--- 步骤 4/7: 安装 mkcert ---"
rm -f mkcert-v*-linux-amd64
curl -JLO --connect-timeout 30 "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
chmod +x mkcert-v*-linux-amd64
sudo mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert
mkcert -install

# --- 步骤 5/7: 设置 Node.js 环境 ---
echo "--- 步骤 5/7: 设置 Node.js 环境 ---"
corepack enable
echo "Node.js/npm/corepack 环境已由 devcontainer feature 和 postCreateCommand 正确加载。"

# --- 步骤 6/7: 安装项目依赖 ---
echo "--- 步骤 6/7: 安装项目依赖 ---"
bundle install
npm ci

# --- 步骤 7/7: 配置环境与收尾 ---
echo "--- 步骤 7/7: 配置环境与收尾 ---"
cp .env.development .env
bin/generate_ssl_certificates
bin/rails db:prepare

echo "--- 所有自动化步骤已成功完成 ---"
echo "下一步: 请手动执行应用启动步骤。"
