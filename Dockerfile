FROM alpine:3.24

RUN apk fix && \
    apk --no-cache --update add git git-lfs netcat-openbsd gpg less openssh patch perl curl bash jq && \
    git lfs install

RUN git config --global user.name "bot"
RUN git config --global user.email "bot"

WORKDIR /app
COPY bot.sh .
COPY manage.sh .

CMD ["bash", "manage.sh", "start_bot"]
