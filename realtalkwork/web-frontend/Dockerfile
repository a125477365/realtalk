FROM nginx:1.27-alpine

ENV API_UPSTREAM=http://api:8000
# NGINX_PORT：nginx 监听端口。bridge 模式保持 80（对外靠 8002:80 映射）；host 模式下
# docker-compose.host.yml 置为 8002，让 nginx 直接监听对外端口（host 模式无端口映射）。
ENV NGINX_PORT=80

COPY web-frontend/templates/ /etc/nginx/templates/
COPY web-frontend/public/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
