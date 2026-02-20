
FROM python:3.9

WORKDIR /app

COPY app.py .

# Install flask + tcpdump + net-tools (needed for Demo 2 sniffing from this pod)
RUN pip install flask && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends tcpdump iproute2 net-tools iputils-ping && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

EXPOSE 5000

# Running as root — intentionally insecure
CMD ["python", "app.py"]
