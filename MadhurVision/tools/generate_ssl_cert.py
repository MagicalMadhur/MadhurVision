"""
MadhurVision — SSL Certificate Generator
==========================================
Generates a self-signed SSL certificate for the WebRTC server.
Safari requires HTTPS to allow getUserMedia camera access.

Usage:
    python tools/generate_ssl_cert.py
    # Creates certs/cert.pem and certs/key.pem
"""

import os
import sys
import datetime
import logging

logger = logging.getLogger("MadhurVision.SSL")


def generate_ssl_cert(
    cert_path: str = "certs/cert.pem",
    key_path: str = "certs/key.pem",
    days_valid: int = 365,
    common_name: str = "MadhurVision"
) -> None:
    """
    Generate a self-signed SSL certificate using the cryptography library.
    Falls back to subprocess openssl if cryptography is not available.
    
    Args:
        cert_path: Output path for the certificate PEM file
        key_path: Output path for the private key PEM file
        days_valid: Certificate validity in days
        common_name: Certificate CN field
    """
    os.makedirs(os.path.dirname(cert_path) or ".", exist_ok=True)
    os.makedirs(os.path.dirname(key_path) or ".", exist_ok=True)

    try:
        _generate_with_cryptography(cert_path, key_path, days_valid, common_name)
    except ImportError:
        logger.warning("'cryptography' package not installed, trying openssl CLI...")
        _generate_with_openssl(cert_path, key_path, days_valid, common_name)


def _generate_with_cryptography(cert_path, key_path, days_valid, common_name):
    """Generate cert using the 'cryptography' Python package."""
    from cryptography import x509
    from cryptography.x509.oid import NameOID
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    # Generate RSA key pair
    key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048
    )

    # Build certificate
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, common_name),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "MadhurVision"),
    ])

    now = datetime.datetime.utcnow()
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=days_valid))
        .add_extension(
            x509.SubjectAlternativeName([
                x509.DNSName("localhost"),
                x509.DNSName("*.local"),
                x509.IPAddress(
                    __import__("ipaddress").IPv4Address("0.0.0.0")
                ),
            ]),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )

    # Write private key
    with open(key_path, "wb") as f:
        f.write(key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption()
        ))

    # Write certificate
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))

    logger.info(f"SSL certificate generated:")
    logger.info(f"  Certificate: {os.path.abspath(cert_path)}")
    logger.info(f"  Private Key: {os.path.abspath(key_path)}")
    logger.info(f"  Valid for: {days_valid} days")


def _generate_with_openssl(cert_path, key_path, days_valid, common_name):
    """Fallback: generate cert using openssl CLI."""
    import subprocess

    cmd = [
        "openssl", "req", "-x509", "-newkey", "rsa:2048",
        "-keyout", key_path,
        "-out", cert_path,
        "-days", str(days_valid),
        "-nodes",
        "-subj", f"/CN={common_name}"
    ]

    try:
        subprocess.run(cmd, check=True, capture_output=True)
        logger.info(f"SSL certificate generated via openssl")
    except FileNotFoundError:
        logger.error(
            "Neither 'cryptography' package nor 'openssl' CLI found.\n"
            "Install cryptography: pip install cryptography\n"
            "Or install OpenSSL and add to PATH."
        )
        raise


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    generate_ssl_cert()
    print("✅ SSL certificates generated successfully!")
