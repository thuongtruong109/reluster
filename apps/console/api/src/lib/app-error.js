export class AppError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.name = "AppError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

export function requireRedisPassword(password) {
  if (!password) {
    throw new AppError(
      503,
      "REDIS_NOT_CONFIGURED",
      "REDIS_PASSWORD chưa được cấu hình cho Reluster Console.",
    );
  }
}

export function requireSentinelPassword(password) {
  if (!password) {
    throw new AppError(
      503,
      "SENTINEL_NOT_CONFIGURED",
      "SENTINEL_PASSWORD chưa được cấu hình cho Reluster Console.",
    );
  }
}
