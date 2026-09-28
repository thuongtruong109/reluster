## Cases studies

##### Restart master sẽ không tự gia nhập thành replica:

- Ở sentinal, khi master failover, thì master sẽ được chọn, tuy nhiên khi master restart lại, thì master sẽ không tự gia nhập thành replica của master mới, mà sẽ trở thành master độc lập. Do đó, cần phải có cơ chế để khi master restart lại, nó sẽ tự động gia nhập vào cluster và trở thành replica của master mới.

- Fix:
  - Hợp nhất master.conf và slave.conf thành template trung lập [redis.conf](D:/Projects/reluster/configs/ha/replica/redis.conf).
  - Khi khởi động, [entrypoint.sh](D:/Projects/reluster/configs/ha/entrypoint.sh) hỏi Sentinel master hiện tại.
  - Nếu địa chỉ master là chính node đó: chạy với vai trò master.
  - Nếu là node khác: tự thêm replicaof <master-mới> 6379.
  - Node đã từng chạy nhưng không liên lạc được Sentinel sẽ từ chối khởi động standalone, tránh split-brain.
  - Logic tìm vai trò được tách riêng trong [role-discovery.sh](D:/Projects/reluster/configs/ha/role-discovery.sh).

##### Sentinel không được bảo vệ

Sentinel đang expose:

```bash
- "26379:26379"
- "26380:26379"
- "26381:26379"
```

Nhưng Sentinel không có authentication/TLS riêng. Redis password chỉ bảo vệ Redis master/replica thông qua:

```bash
sentinel auth-pass mymaster ${REDIS_PASSWORD}
```

Nó không bảo vệ cổng Sentinel khỏi các lệnh quản trị. Với port được publish ra host/network, client có thể gọi các lệnh Sentinel như:

```bash
- SENTINEL FAILOVER <master-name>
- SENTINEL RESET <master-name>
- SENTINEL REMOVE <master-name>
```

- Fix:
  - Không expose Sentinel ra public network.
  - Firewall chỉ cho application/Redis operators truy cập.
  - Dùng ACL/TLS nếu môi trường yêu cầu.
  - Tách management network.
  - Thêm SENTINEL_PASSWORD riêng và requirepass cho Sentinel tại [sentinel.conf (line 3)](D:/Projects/reluster/configs/ha/sentinel/sentinel.conf:3).
  - Chỉ publish các cổng Sentinel trên 127.0.0.1 tại [docker-compose.ha.yml (line 112)](D:/Projects/reluster/docker-compose.ha.yml:112).
  - Role discovery khi node restart xác thực với Sentinel, nên vẫn tìm đúng master mới tại [role-discovery.sh (line 6)](D:/Projects/reluster/configs/ha/role-discovery.sh:6).
  - Console dùng credential Sentinel riêng cho status, discovery và failover.
  - Security scan kiểm tra trực tiếp:- Không mật khẩu → NOAUTH Authentication required.
  - Đúng mật khẩu → PONG.

##### Không có cơ chế đảm bảo write durability

Replication mặc định là asynchronous. Khi master chết đột ngột, những write chưa replicate có thể mất.

- Fix:
  - Mặc định yêu cầu 1 replica khỏe, lag tối đa 10s trong [cấu hình dùng chung (line 1)](/D:/Projects/reluster/configs/common/write-durability.sh:1), [HA (line 9)](/D:/Projects/reluster/configs/ha/replica/redis.conf:9) và [Cluster (line 8)](/D:/Projects/reluster/configs/cluster/node.conf:8).
  ```bash
  min-replicas-to-write 1
  min-replicas-max-lag 10
  ```

  - Khi không đủ replica, Redis trả NOREPLICAS thay vì tiếp tục nhận write có nguy cơ mất dữ liệu. Có thể điều chỉnh qua [.env.example (line 5)](/D:/Projects/reluster/.env.example:5); đặt REDIS_MIN_REPLICAS_TO_WRITE=0 để ưu tiên availability.
