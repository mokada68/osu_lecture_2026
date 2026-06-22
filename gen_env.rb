#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

# ---------------------------------------------------------------------------
# Ethernet / Wi-Fi 挙動観測実習 環境構築スクリプト
# 実行条件: sudo ruby setup_l2_lab.rb
# ---------------------------------------------------------------------------

# エラーハンドリング: ルート権限チェック
if Process.euid != 0
  puts "[-] このスクリプトはルート権限（sudo）で実行する必要があります。"
  exit 1
end

puts "[+] 実習環境の構築を開始します..."

# 1. 仮想ブリッジ (Linux Bridge) の作成
puts "[+] 仮想ブリッジ (br0) を作成しています..."
system("ip link add name br0 type bridge")
system("ip link set dev br0 up")

# 2. ホスト情報の設定（名前空間名、IPアドレス、MACアドレス末尾）
hosts = [
  { name: "ns-h1", ip: "192.168.100.1/24", mac: "00:00:00:00:00:01" },
  { name: "ns-h2", ip: "192.168.100.2/24", mac: "00:00:00:00:00:02" },
  { name: "ns-h3", ip: "192.168.100.3/24", mac: "00:00:00:00:00:03" }
]

# 3. 各ホスト（名前空間）および仮想リンク（veth）の作成と接続
hosts.each do |h|
  puts "[+] ホスト #{h[:name]} を作成中..."
  
  # ネットワーク名前空間の作成
  system("ip netns add #{h[:name]}")
  
  # vethペア（ホスト側インターフェース と ブリッジ側インターフェース）の作成
  veth_host = "veth-#{h[:name].split('-')[1]}"      # 例: veth-h1
  veth_bridge = "veth-#{h[:name].split('-')[1]}-br" # 例: veth-h1-br
  system("ip link add #{veth_host} type veth peer name #{veth_bridge}")
  
  # ブリッジ側インターフェースを Bridge (br0) に接続
  system("ip link set #{veth_bridge} master br0")
  system("ip link set dev #{veth_bridge} up")
  
  # ホスト側インターフェースを対応するネットワーク名前空間に移動
  system("ip link set #{veth_host} netns #{h[:name]}")
  
  # 名前空間内でのインターフェース有効化、IPアドレス・固定MACアドレスの設定
  # ※実習の視認性を高めるため、MACアドレスを固定値に設定します
  system("ip netns exec #{h[:name]} ip link set dev #{veth_host} address #{h[:mac]}")
  system("ip netns exec #{h[:name]} ip addr add #{h[:ip]} dev #{veth_host}")
  system("ip netns exec #{h[:name]} ip link set dev #{veth_host} up")
  
  # ループバックインターフェース (lo) の有効化
  system("ip netns exec #{h[:name]} ip link set dev lo up")
end

puts "[+] すべてのホストとブリッジが正常に接続され、有効化されました。"
puts "[+] 【確認コマンド】: ip netns list"
puts "[+] 【削除コマンド】: sudo ip link del br0 && sudo ip netns del ns-h1 && sudo ip netns del ns-h2 && sudo ip netns del ns-h3"
puts "[+] 環境構築が完了しました。実習を開始してください。"