/** Matches the estate's HTTPError: a status and a message a client can read. */
export class HTTPError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
    this.name = this.constructor.name;
    Object.setPrototypeOf(this, new.target.prototype);
    Error.captureStackTrace?.(this, this.constructor);
  }
}

/**
 * A rule of the domain was broken — an unknown test code, a patient that does
 * not exist. 400, because the request was wrong rather than the server.
 */
export class DomainError extends HTTPError {
  constructor(message: string) {
    super(400, message);
  }
}

export class NotFoundError extends HTTPError {
  constructor(message = 'Not found') {
    super(404, message);
  }
}
