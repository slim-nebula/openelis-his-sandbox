/**
 * Errors that already know their status code, so a handler can throw one and
 * let the error middleware turn it into a response.
 *
 * Same shape as his-api's and patient-service's, deliberately: three services,
 * one exception hierarchy.
 */
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
