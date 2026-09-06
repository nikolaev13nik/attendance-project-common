# [Time Tracking] - Project Overview & Specifications

## 1. High-Level Summary
This learning project/app gives organizations the ability to track worker hours and employee attendance. It provides statistical aggregations and hour calculations for downstream salary processing, enhanced by AI-driven automated assistance and notifications.

## 2. Tech Stack & Tools
* **Backend / Language:** Java 21, Spring Boot, SQL, Kafka, API Gateway, AI Agentic Workflows
* **Database / Infrastructure:** PostgreSQL, Docker, GCP (Google Cloud Platform), CI/CD, Kubernetes
* **Key Libraries / Frameworks:** Swagger/OpenAPI, Jackson, Spring Cloud / Microservices

## 3. Architecture & Microservice Inventory
The system consists of **4 core microservices**:

1. **API Gateway & Service Discovery (Eureka / Load Balancer):**
    * Entry point routing incoming traffic to appropriate backend services.

2. **Accounting Microservice:**
    * Handles user registration, role management (`addRole`, `removeRole`), user deletion, and authentication (`login`).
    * Manages PostgreSQL tables: `users` and `roles`.
    * Issues JWTs containing user roles for subsequent authenticated REST requests.

3. **AttendanceTimeTracking Microservice:**
    * Manages daily employee clock-in/out stamps (`start` and `finish` timestamps) allowing multiple entries/exits per day.
    * Provides administrative APIs (`editRecord`, `removeRecord`, `calculateOverTime`, `calculateTotalHours`, `calculateTotalDays`).
    * **Monthly Statistics Calculation REST API:**
        * Exposes an endpoint to compute monthly statistics for a given user.
        * Query Parameter: `report` (boolean, default: `false`).
        * **If `report=false`:** Calculates required monthly statistics and saves the record in PostgreSQL (`monthly_user_statistics`). Returns calculated statistics in the REST response.
        * **If `report=true`:** Calculates required statistics, saves them to DB, and triggers an asynchronous Kafka event containing the past 6 months of historical data to invoke the AI assistance & email workflow.
    * **Database (Database-per-Service Pattern):**
        * `time_records`: Daily raw clocking logs per `userId`.
        * `monthly_user_statistics`: Aggregated monthly statistics (total hours, overtime, days worked) per user/tenant.
    * **Internal Schedulers:**
        * *Daily Conflict Scheduler (Runs nightly):* Scans for broken records from the previous day, queries 6-month historical averages locally from `monthly_user_statistics`, groups by `tenantId`, and dispatches `AttendanceConflictBatchDetectedEvent` to Kafka.
        * *Monthly Aggregation Scheduler (Runs 1st night of the month):* Automatically triggers calculation for all users, saves results, and dispatches `EnrichedMonthlyContextEvent` to Kafka.

4. **AI Assistance & Notification Microservice (Combined MS):**
    * Consumes Kafka events for daily conflict resolution and monthly trend insights.
    * **AI Module:** Evaluates conflict batches and monthly statistical context using LLMs/rules against 6-month historical baselines to generate structured suggestions, anomaly flags, and summaries.
    * **Notification Module:** Takes AI-generated suggestions/summaries, builds structured HTML email templates, and dispatches email notifications to admins and employees.

---

## 4. Main Challenges & Discussion Goals
* **Project Purpose:** Demonstrate microservices architecture, Kafka event-driven patterns, AI agentic workflows, Docker, Kubernetes, and GCP deployment.
* **Infrastructure Cost Efficiency:** Maintain lightweight footprint by merging AI and Notification services to minimize resource overhead for local execution (Docker/K8s) and cloud hosting (GCP).

---

## 5. Async Flow: Daily Conflict Resolver