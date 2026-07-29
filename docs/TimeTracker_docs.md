# [Time Tracking] - Project Overview & Specifications


## 1. High-Level Summary
- This learning project / app gives organizations the ability to track worker hours and employee attendance[cite: 1].
- Provides statistical aggregations and hour calculations for downstream salary processing[cite: 1].


## 2. Tech Stack & Tools
- **Backend / Language:** Java 21, Spring Boot, SQL, Kafka, API Gateway, AI Agentic Workflows[cite: 1]
- **Database / Infrastructure:** PostgreSQL, Docker, GCP (Google Cloud Platform),CI/CD,  Kubernetes[cite: 1]
- **Key Libraries / Frameworks:** Swagger/OpenAPI, Jackson, Spring Cloud / Microservices[cite: 1]


## 3. Architecture & Microservice Inventory
The system consists of **5 core microservices**:

1. **API Gateway & Service Discovery (Eureka / Load Balancer):** Entry point routing incoming traffic to appropriate backend services[cite: 1].
2. **Accounting Microservice:**
   - Handles user registration, role management (`addRole`, `removeRole`), user deletion, and authentication (`login`)[cite: 1].
   - Manages PostgreSQL tables: `users` and `roles`[cite: 1].
   - Issues JWTs containing user roles for subsequent authenticated REST requests[cite: 1].
3. **AttendanceTimeTracking Microservice:**
   - Manages daily employee clock-in/out stamps (`start` and `finish` timestamps) allowing multiple entries/exits per day[cite: 1].
   - Provides administrative APIs (`editRecord`, `removeRecord`, `calculateOverTime`, `calculateTotalHours`, `calculateTotalDays`)[cite: 1].
   - **Database (Database-per-Service Pattern):**
     - `time_records`: Daily raw clocking logs per `userId`[cite: 1].
     - `monthly_user_statistics`: Aggregated monthly statistics (total hours, overtime, days worked) per user/tenant[cite: 1].
   - **Internal Schedulers:**
     - **Daily Conflict Scheduler (Runs nightly):** Scans for broken records (missing start/finish times) from the previous day[cite: 1]. Queries 6-month historical averages locally from `monthly_user_statistics`, groups by `tenantId`, and dispatches a batch event to Kafka[cite: 1].
     - **Monthly Aggregation Scheduler (Runs 1st night of the month):** Calculates current month totals per user[cite: 1]. Saves results into local `monthly_user_statistics` table[cite: 1], fetches the past 3–6 months baseline stats, and dispatches an enriched context event to Kafka[cite: 1].
4. **AIDecisionAssistant Microservice:**
   - **Stateless service** incorporating AI agents and prompt handling[cite: 1].
   - Consumes Kafka batch events for unresolved daily records and uses preset rules + 6-month user history to recommend resolutions[cite: 1].
   - Consumes monthly enriched context events to analyze tenant-level trends, anomalies, and executive insights[cite: 1].
5. **Notification Microservice:**
   - **Stateless service** that consumes suggested resolutions and monthly executive insights[cite: 1].
   - Formats HTML email templates and sends notifications to company admins and employees[cite: 1].


## 4. Main Challenges & Discussion Goals
- **Project Purpose:** Demonstrate microservices architecture, Kafka event-driven patterns, AI agentic workflows, Docker, Kubernetes, and GCP deployment[cite: 1].
- **Infrastructure Cost Efficiency:** Maintain lightweight footprint to minimize resource requirements for local execution (Docker/K8s) and cloud hosting (GCP) while following clean domain boundary rules[cite: 1].


## 5. Async Flow: Daily Conflict Resolver
[1. AttendanceTimeTracking MS]
│
├── (Nightly Scheduler finds unresolved daily records grouped by tenantId)
│
│ 1. Queries local DB (monthly_user_statistics) for 6-month user history
│ 2. Assembles batch payload with conflict details + historical averages
│
└── Publishes: AttendanceConflictBatchDetectedEvent
│
▼
[Kafka Topic: attendance-conflicts]
│
▼
[2. AIDecisionAssistant MS]
│
├── Consumes batch (1 LLM call per tenant)
├── Generates structured suggestions using rules + historical context
│
└── Publishes: ResolutionSuggestedEvent
│
▼
[Kafka Topic: resolution-suggestions]
│
▼
[3. Notification MS]
│
└── Consumes event & emails Admin + Employee with AI suggestion


## 6. Async Flow: Monthly Statistics & AI Trend Insights
[1. AttendanceTimeTracking MS]
│
├── (Runs on 1st of month at midnight)
│
│ 1. Calculates current month totals per user & saves to monthly_user_statistics DB
│ 2. Queries past 3–6 months baseline stats from monthly_user_statistics DB
│ 3. Assembles enriched payload (Current Month + 3-6 Month History)
│
└── Publishes: EnrichedMonthlyContextEvent
│
▼
[Kafka Topic: enriched-monthly-context]
│
▼
[2. AIDecisionAssistant MS]
│
├── Consumes enriched payload
├── Runs 1 LLM call per tenant (analyzes trends, anomalies, & overtime spikes)
│
└── Publishes: MonthlyInsightEvent
│
▼
[Kafka Topic: monthly-insights]
│
▼
[3. Notification MS]
│
└── Emails Company Admin with AI Executive Summary & Trend Report




