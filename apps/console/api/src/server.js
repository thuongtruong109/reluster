import express from "express";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config } from "./config.js";
import { AppError } from "./lib/app-error.js";
import { apiRouter } from "./routes/api.js";

const app = express();
const currentDirectory = path.dirname(fileURLToPath(import.meta.url));
const webDirectory = path.resolve(currentDirectory, "../../web");

app.disable("x-powered-by");
app.use(express.json({ limit: "32kb" }));
app.use((_request, response, next) => {
  response.set({
    "Content-Security-Policy": "default-src 'self'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
  });
  next();
});

app.use("/api", apiRouter);
app.use(express.static(webDirectory, { extensions: ["html"], maxAge: process.env.NODE_ENV === "production" ? "1h" : 0 }));
app.get("/*splat", (_request, response) => response.sendFile(path.join(webDirectory, "index.html")));

app.use((error, request, response, _next) => {
  const status = error instanceof AppError ? error.status : 500;
  if (status >= 500) console.error(`[${request.method} ${request.path}]`, error.message);
  response.status(status).json({
    error: {
      code: error.code ?? "INTERNAL_ERROR",
      message: error instanceof AppError ? error.message : "Reluster Console gặp lỗi không mong muốn.",
      ...(error instanceof AppError && error.details ? { details: error.details } : {}),
    },
  });
});

app.listen(config.port, "0.0.0.0", () => {
  console.log(`Reluster Console listening on http://localhost:${config.port}`);
});
