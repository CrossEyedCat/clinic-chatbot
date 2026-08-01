FROM rasa/rasa:3.6.21

WORKDIR /app
USER root
COPY . /app
RUN chown -R 1001:1001 /app
USER 1001

# Train the model at build time so the Space starts instantly
RUN rasa train

EXPOSE 7860

# rasa image has ENTRYPOINT ["rasa"] - override it to run both servers:
# the action server (form validation) on 5055 and the Rasa API on 7860
ENTRYPOINT []
CMD ["bash", "-c", "rasa run actions --port 5055 & exec rasa run --enable-api --cors '*' --port 7860 --endpoints endpoints.yml"]
