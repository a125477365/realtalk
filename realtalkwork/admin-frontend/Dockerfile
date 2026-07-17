FROM nginx:1.27-alpine

# API_UPSTREAM 由环境变量注入（默认同 compose 网络内的 api 服务），支持跨机部署
ENV API_UPSTREAM=http://api:8000
# NGINX_PORT：nginx 监听端口。bridge 模式保持 80（对外靠 8001:80 映射）；host 模式下
# docker-compose.host.yml 置为 8001，让 nginx 直接监听对外端口（host 模式无端口映射）。
ENV NGINX_PORT=80

COPY admin-frontend/templates/ /etc/nginx/templates/
COPY admin-frontend/public/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
