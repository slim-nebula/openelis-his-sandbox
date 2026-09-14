import { networkInterfaces } from 'node:os';
import { createConnection } from 'node:net';
import { config } from './env.js';
import { logger } from './logger.js';
/**
 * Registers this service with Consul, matching the estate's tags and check
 * timings exactly. Kong routes to <name>.service.consul, and Consul answers
 * only with instances whose check is passing — so these numbers decide how
 * quickly a failed instance stops receiving traffic.
 */
export class ConsulRegistration {
    serviceName;
    port;
    healthCheckPath;
    serviceId;
    constructor(serviceName = config.serviceName, port = config.port, healthCheckPath = '/health') {
        this.serviceName = serviceName;
        this.port = port;
        this.healthCheckPath = healthCheckPath;
        this.serviceId = `${serviceName}-${process.env.HOSTNAME || Math.random().toString(36).slice(2, 10)}`;
    }
    /**
     * The address Consul can actually reach this container on.
     *
     * NOT simply eth0, and this service is the reason the rule exists. The bridge
     * sits on THREE networks — sandbox, integration and data — because that
     * separation is the boundary the whole architecture rests on. Taking eth0
     * registered it at its data-network address while Consul watches the sandbox
     * network: it appeared in the catalogue and failed every health check. A
     * service in the catalogue that Consul cannot reach is worse than one that
     * never registered, because Kong routes to what it finds.
     *
     * So ask the routing table instead. Opening a socket toward Consul and
     * reading the local end tells us which address the kernel would use to get
     * there, which is exactly the one to advertise.
     *
     * Worth knowing for the real HIS too: the moment any service there joins a
     * second network, its eth0 registration becomes a coin flip.
     */
    async advertisableAddress() {
        if (config.consul.advertisedIp)
            return config.consul.advertisedIp;
        const routed = await new Promise((resolve) => {
            const socket = createConnection({ host: config.consul.host, port: config.consul.port });
            const done = (value) => {
                socket.destroy();
                resolve(value);
            };
            socket.once('connect', () => done(socket.localAddress ?? null));
            socket.once('error', () => done(null));
            socket.setTimeout(2000, () => done(null));
        });
        if (routed && !routed.startsWith('127.'))
            return routed;
        return this.containerAddress();
    }
    /** eth0, then any non-internal IPv4, then the service name. */
    containerAddress() {
        const nets = networkInterfaces();
        for (const net of nets.eth0 ?? []) {
            if (net.family === 'IPv4' && !net.internal)
                return net.address;
        }
        for (const name of Object.keys(nets)) {
            for (const net of nets[name] ?? []) {
                if (net.family === 'IPv4' && !net.internal)
                    return net.address;
            }
        }
        return this.serviceName;
    }
    async register() {
        if (!config.consul.host) {
            logger.info('Consul registration is off: CONSUL_HOST is not set');
            return;
        }
        const address = await this.advertisableAddress();
        const body = {
            ID: this.serviceId,
            Name: this.serviceName,
            Address: address,
            Port: this.port,
            Tags: ['hospital', 'microservice', 'load-balanced', `version-${config.serviceVersion}`],
            Check: {
                Name: `${this.serviceName}-health`,
                HTTP: `http://${address}:${this.port}${this.healthCheckPath}`,
                Interval: '10s',
                Timeout: '3s',
                DeregisterCriticalServiceAfter: '30s',
            },
        };
        try {
            const response = await fetch(`http://${config.consul.host}:${config.consul.port}/v1/agent/service/register`, { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
            if (!response.ok)
                throw new Error(`Consul returned ${response.status}`);
            logger.info(`Registered ${this.serviceName} with Consul as ${this.serviceId} at ${address}:${this.port}`);
        }
        catch (error) {
            // Deliberately NOT process.exit(1), which is what the estate's services
            // do. The bridge's job is moving patient results, and it does that
            // perfectly well unregistered — OpenELIS polls it by name and Kafka
            // consults no registry. Refusing to start over a registry outage would
            // convert a discovery problem into a laboratory outage.
            logger.error(`Could not register with Consul; continuing unregistered: ${error.message}`);
        }
    }
    async deregister() {
        if (!config.consul.host)
            return;
        try {
            await fetch(`http://${config.consul.host}:${config.consul.port}/v1/agent/service/deregister/${this.serviceId}`, { method: 'PUT' });
            logger.info(`Deregistered ${this.serviceId} from Consul`);
        }
        catch (error) {
            // Consul's own DeregisterCriticalServiceAfter clears this in 30s.
            logger.warn(`Could not deregister ${this.serviceId}: ${error.message}`);
        }
    }
}
