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
