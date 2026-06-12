FROM nginx:1.27-alpine

ENV API_UPSTREAM=http://api:8000

COPY web-frontend/templates/ /etc/nginx/templates/
COPY web-frontend/public/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
