<?php
// open.php  -  Pagina de apertura RDP
// La autenticacion la hace Apache (mod_auth_openidc) ANTES de llegar aqui.
// NO recibe ningun parametro de usuario: solo usa la IP del peer TCP
// (REMOTE_ADDR), validada como IPv4 estricta. NO se confia en X-Forwarded-For.
declare(strict_types=1);

$ip = $_SERVER['REMOTE_ADDR'] ?? '';

if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) === false) {
    http_response_code(400);
    header('Content-Type: text/plain; charset=utf-8');
    exit("IP de origen no valida para apertura RDP ($ip). "
       . "Conexion IPv6 o tras proxy: el RDP solo se abre para IPv4 directa.");
}

$sock = @stream_socket_client("unix:///run/rdp-gate.sock", $errno, $errstr, 3);
if ($sock === false) {
    http_response_code(502);
    header('Content-Type: text/plain; charset=utf-8');
    exit("No se pudo contactar el servicio de apertura ($errstr)");
}
fwrite($sock, $ip . "\n");
$resp = trim((string) fgets($sock, 16));
fclose($sock);

header('Content-Type: text/html; charset=utf-8');
$ipsafe = htmlspecialchars($ip, ENT_QUOTES, 'UTF-8');

if ($resp === 'OK') {
    echo "<!doctype html><meta charset='utf-8'>"
       . "<h2>RDP abierto</h2>"
       . "<p>Acceso concedido para <b>$ipsafe</b> durante <b>1 hora</b>.</p>"
       . "<p>Ya puedes abrir tu cliente RDP contra rdp.forseti.es. "
       . "Pasada la hora vuelve a cargar esta pagina para renovar.</p>";
} else {
    http_response_code(500);
    echo "<!doctype html><meta charset='utf-8'>"
       . "<h2>Error</h2><p>No se pudo abrir el acceso para $ipsafe.</p>";
}
