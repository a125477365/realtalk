FROM nginx:1.27-alpine

RUN apk add --no-cache bash

COPY admin-frontend/nginx.conf /etc/nginx/conf.d/default.conf
COPY admin-frontend/public/ /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
