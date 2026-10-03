# emotional-intelligence

The goal of this project is to give desktop agents emotional intelligence. In particular, to allow them to understand body language as they work with you. This project runs **100% Locally* to preserve privacy.

### How it works
A local scheduled jobs polls the desktop camera at regular intervals. Local models are used to assess the image for your emotional state, and the results are saved in a local database. An MCP connector enables desktop agents to access the results (importantly not the images).

### Future work
In the future, keyboard inputs, biometrics, and an agent's own assesment of your emotional state could be included.

### Other uses
While emotional intelligence is the primary aim, this project may be used to give agents insights into arbitrary behaviors observable through desktop camera. For example, monitoring for bad posture.
