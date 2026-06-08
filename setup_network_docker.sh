#!/bin/bash
# ---------------------------------------------------------------
# 講義用：第2回 動的ルーティング＆DHCP・DNS統合演習 構築スクリプト
# 💡 Windows(WSL2) & Apple Silicon Mac(UTM/Parallels) 100%ネイティブ極上安定版
# ---------------------------------------------------------------
set -e

if [ "$EUID" -ne 0 ]; then
  echo "エラー: このスクリプトは sudo をつけて実行してください。"
  exit 1
fi

echo "=== 1. 古いコンテナとnetnsの掃除 ==="
docker rm -f R1 R2 R3 Client Server 2>/dev/null || true
rm -rf /var/run/netns/ns-r1 /var/run/netns/ns-r2 /var/run/netns/ns-r3 /var/run/netns/ns-client /var/run/netns/ns-server 2>/dev/null || true

echo "=== 2. コンテナの起動（ネイティブイメージを使用） ==="
# 💡 Alpineやnetshootは完全にマルチアーキテクチャ対応のため、エミュレーションなしで100%ネイティブ動作します。
docker run -d --privileged --name R1 alpine sleep infinity
docker run -d --privileged --name R2 alpine sleep infinity
docker run -d --privileged --name R3 alpine sleep infinity
docker run -d --privileged --name Client nicolaka/netshoot sleep infinity
docker run -d --privileged --name Server nicolaka/netshoot sleep infinity

echo "=== 3. 必要なツールの事前インストール ==="
# 💡 起動したすべてのコンテナの中で直接、そのマシンのCPUに適合したバイナリを高速インストールします。
# 💡 これにより、後半の演習で使用する DHCP や DNS（dnsmasq）がないエラーを完全に防止します。
for router in R1 R2 R3; do
    docker exec $router apk update > /dev/null
    docker exec $router apk add frr dnsmasq > /dev/null
done

echo ">> Server/Client の追加ツールをインストール中..."
docker exec Server apk update > /dev/null && docker exec Server apk add dnsmasq > /dev/null
# 💡 Alpine Linuxにおいて標準かつ軽量な「dhcpcd」クライアントを導入し、パッケージ未検出エラーを根絶します。
docker exec Client apk update > /dev/null && docker exec Client apk add dhcpcd > /dev/null

echo "=== 4. 外部ネットワークの切断 ==="
for container in R1 R2 R3 Client Server; do
    docker network disconnect bridge $container 2>/dev/null || true
done

echo "=== 5. netnsへの紐付け ==="
mkdir -p /var/run/netns
ln -sfT /proc/$(docker inspect -f '{{.State.Pid}}' R1)/ns/net /var/run/netns/ns-r1
ln -sfT /proc/$(docker inspect -f '{{.State.Pid}}' R2)/ns/net /var/run/netns/ns-r2
ln -sfT /proc/$(docker inspect -f '{{.State.Pid}}' R3)/ns/net /var/run/netns/ns-r3
ln -sfT /proc/$(docker inspect -f '{{.State.Pid}}' Client)/ns/net /var/run/netns/ns-client
ln -sfT /proc/$(docker inspect -f '{{.State.Pid}}' Server)/ns/net /var/run/netns/ns-server

echo "=== 6. 仮想リンク（veth）の配線 ==="
ip link add veth-r1r2 type veth peer name veth-r2r1
ip link set veth-r1r2 netns ns-r1 && ip link set veth-r2r1 netns ns-r2
ip link add veth-r1r3 type veth peer name veth-r3r1
ip link set veth-r1r3 netns ns-r1 && ip link set veth-r3r1 netns ns-r3
ip link add veth-r2r3 type veth peer name veth-r3r2
ip link set veth-r2r3 netns ns-r2 && ip link set veth-r3r2 netns ns-r3
ip link add veth-cli type veth peer name veth-r1cli
ip link set veth-cli netns ns-client && ip link set veth-r1cli netns ns-r1
ip link add veth-srv type veth peer name veth-r2srv
ip link set veth-srv netns ns-server && ip link set veth-r2srv netns ns-r2

echo "=== 7. インタフェースの有効化と固定IP設定 ==="
for ns in ns-r1 ns-r2 ns-r3 ns-client ns-server; do
    ip netns exec $ns ip link set lo up
done
ip netns exec ns-r1 ip link set veth-r1r2 up && ip netns exec ns-r2 ip link set veth-r2r1 up
ip netns exec ns-r1 ip link set veth-r1r3 up && ip netns exec ns-r3 ip link set veth-r3r1 up
ip netns exec ns-r2 ip link set veth-r2r3 up && ip netns exec ns-r3 ip link set veth-r3r2 up
ip netns exec ns-client ip link set veth-cli up && ip netns exec ns-r1 ip link set veth-r1cli up
ip netns exec ns-server ip link set veth-srv up && ip netns exec ns-r2 ip link set veth-r2srv up

ip netns exec ns-r1 ip addr add 10.0.12.1/24 dev veth-r1r2
ip netns exec ns-r2 ip addr add 10.0.12.2/24 dev veth-r2r1
ip netns exec ns-r1 ip addr add 10.0.13.1/24 dev veth-r1r3
ip netns exec ns-r3 ip addr add 10.0.13.3/24 dev veth-r3r1
ip netns exec ns-r2 ip addr add 10.0.23.2/24 dev veth-r2r3
ip netns exec ns-r3 ip addr add 10.0.23.3/24 dev veth-r3r2
ip netns exec ns-r1 ip addr add 192.168.10.1/24 dev veth-r1cli
ip netns exec ns-r2 ip addr add 192.168.20.1/24 dev veth-r2srv

ip netns exec ns-server ip addr add 192.168.20.100/24 dev veth-srv
ip netns exec ns-server ip route add default via 192.168.20.1

ip netns exec ns-r1 sysctl -w net.ipv4.ip_forward=1 > /dev/null
ip netns exec ns-r2 sysctl -w net.ipv4.ip_forward=1 > /dev/null
ip netns exec ns-r3 sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo "=== 8. Client의 初期ネットワーク設定（手動設定を模擬） ==="
# 💡 講義をスムーズに進めるため、あらかじめClientにIPとゲートウェイを仕込みます
ip netns exec ns-client ip addr add 192.168.10.10/24 dev veth-cli
ip netns exec ns-client ip route add default via 192.168.10.1

echo "=== 8.5 FRR設定ファイルの完全初期化と書き込み権限の完全開放 ==="
# 💡 write memory時のパーミッション制限や、直接書き込み警告メッセージ(Warning)を100%防ぎます。
# 💡 vtysh.confに「service integrated-vtysh-config」を定義することで、保存の不整合を排除します。
for router in R1 R2 R3; do
    docker exec $router mkdir -p /var/run/frr /etc/frr
    docker exec $router touch /etc/frr/frr.conf /etc/frr/vtysh.conf
    docker exec $router sh -c "echo 'service integrated-vtysh-config' > /etc/frr/vtysh.conf"
    docker exec $router chown -R frr:frr /etc/frr /var/run/frr
    docker exec $router chmod -R 777 /etc/frr /var/run/frr
done

echo "=== 9. OSPFデーモン（ネイバー）のネイティブ安全起動 ==="
# 💡 設定ファイル(/etc/frr/daemons)でospfdを有効化した上で、Alpine標準の起動統合マネージャー(frrinit.sh)を使用します。
# 💡 これにより、zebra、ospfd、watchfrrが公式の想定する完璧な整合性と依存関係で起動し、Warningが100%根絶されます。
for router in R1 R2 R3; do
    docker exec $router sed -i 's/ospfd=no/ospfd=yes/g' /etc/frr/daemons
    docker exec -d $router /usr/lib/frr/frrinit.sh start
done

echo "🎉 環境構築が100%完了しました！"