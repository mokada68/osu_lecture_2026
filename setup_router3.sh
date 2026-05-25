#!/bin/bash

# 本スクリプトは管理者権限で実行する必要があります。
if [ "$EUID" -ne 0 ]; then
  echo "エラー: このスクリプトは sudo を付けて実行してください。"
  exit 1
fi

echo "=== 三角形ルーティング演習ネットワークの自動構築を開始します ==="

# 1. 既存の環境をクリーンアップ（初期化）
echo "[1/4] 既存の仮想環境（netns）をリセット中..."
ip -all netns delete 2>/dev/null

# 2. Namespaceの作成
echo "[2/4] 仮想ノード(PCとルーター)を作成中..."
for ns in pca pcb r1 r2 r3; do
    ip netns add $ns
    ip netns exec $ns ip link set lo up
done

# 3. 仮想ケーブル（vethペア）の作成と接続
echo "[3/4] 仮想ケーブルを配線中..."
# PC - ルーター間
ip link add veth-pca type veth peer name veth-ra
ip link set veth-pca netns pca
ip link set veth-ra netns r1

ip link add veth-pcb type veth peer name veth-rb
ip link set veth-pcb netns pcb
ip link set veth-rb netns r2

# ルーター間 (R1-R2, R2-R3, R3-R1) の三角形接続
ip link add veth-r1-r2 type veth peer name veth-r2-r1
ip link set veth-r1-r2 netns r1
ip link set veth-r2-r1 netns r2

ip link add veth-r2-r3 type veth peer name veth-r3-r2
ip link set veth-r2-r3 netns r2
ip link set veth-r3-r2 netns r3

ip link add veth-r3-r1 type veth peer name veth-r1-r3
ip link set veth-r3-r1 netns r3
ip link set veth-r1-r3 netns r1

# 4. IPアドレスの割り当てとリンクアップ
echo "[4/4] IPアドレスを設定し、インターフェースを起動中..."

# PC-A と R1 間 (192.168.1.0/24)
ip netns exec pca ip addr add 192.168.1.1/24 dev veth-pca
ip netns exec pca ip link set veth-pca up
ip netns exec pca ip route add default via 192.168.1.254
ip netns exec r1 ip addr add 192.168.1.254/24 dev veth-ra
ip netns exec r1 ip link set veth-ra up

# PC-B と R2 間 (192.168.2.0/24)
ip netns exec pcb ip addr add 192.168.2.1/24 dev veth-pcb
ip netns exec pcb ip link set veth-pcb up
ip netns exec pcb ip route add default via 192.168.2.254
ip netns exec r2 ip addr add 192.168.2.254/24 dev veth-rb
ip netns exec r2 ip link set veth-rb up

# R1 - R2 間 (10.0.12.0/24)
ip netns exec r1 ip addr add 10.0.12.1/24 dev veth-r1-r2
ip netns exec r1 ip link set veth-r1-r2 up
ip netns exec r2 ip addr add 10.0.12.2/24 dev veth-r2-r1
ip netns exec r2 ip link set veth-r2-r1 up

# R2 - R3 間 (10.0.23.0/24)
ip netns exec r2 ip addr add 10.0.23.2/24 dev veth-r2-r3
ip netns exec r2 ip link set veth-r2-r3 up
ip netns exec r3 ip addr add 10.0.23.3/24 dev veth-r3-r2
ip netns exec r3 ip link set veth-r3-r2 up

# R3 - R1 間 (10.0.13.0/24)
ip netns exec r3 ip addr add 10.0.13.3/24 dev veth-r3-r1
ip netns exec r3 ip link set veth-r3-r1 up
ip netns exec r1 ip addr add 10.0.13.1/24 dev veth-r1-r3
ip netns exec r1 ip link set veth-r1-r3 up

# 各ルーターでIPフォワーディング（パケット転送）を有効化
for ns in r1 r2 r3; do
    ip netns exec $ns sysctl -wq net.ipv4.ip_forward=1
done

# ============================================================
# 【教育的コア】スタティックルーティングによる三角形経路の構築
# ============================================================
echo "ルーティングテーブルを手動で構築しています（演習の核心）..."

# R1に対し、PC-B側(192.168.2.0/24)への行き先を教える
# 通常経路：R2経由 (10.0.12.2)
ip netns exec r1 ip route add 192.168.2.0/24 via 10.0.12.2

# R2に対し、PC-A側(192.168.1.0/24)への行き先を教える
# 通常経路：R1経由 (10.0.12.1)
ip netns exec r2 ip route add 192.168.1.0/24 via 10.0.12.1

# 迂回用として、R3（頂点）を経由するネットワーク情報も設定
ip netns exec r1 ip route add 10.0.23.0/24 via 10.0.13.3
ip netns exec r2 ip route add 10.0.13.0/24 via 10.0.23.3

echo "--> 経路の構築が完了しました！（1秒の遅延もなく即座に開通します）"
echo ""

echo "=== 構築が完了しました！ ==="
echo "PC-A (192.168.1.1) から PC-B (192.168.2.1) への疎通テストを実行します。"
echo "------------------------------------------------------------"
ip netns exec pca ping -c 3 192.168.2.1