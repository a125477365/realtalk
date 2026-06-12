FROM nginx:1.27-alpine

# API_UPSTREAM 由环境变量注入（默认同 compose 网络内的 api 服务），支持跨机部署
ENV API_UPSTREAM=http://api:8000

COPY admin-frontend/templates/ /etc/nginx/templates/
COPY admin-frontend/public/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
