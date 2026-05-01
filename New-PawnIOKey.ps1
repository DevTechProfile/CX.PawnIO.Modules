# Generates an RSA-2048 PKCS#1 private key in PEM format for PawnIOUtil sign.
# Self-contained: works on Windows PowerShell 5.1 (no OpenSSL, no PS7 required).
[CmdletBinding()]
param(
    [string]$OutPath = (Join-Path $PSScriptRoot 'my.key')
)

$ErrorActionPreference = 'Stop'

function Encode-Length([int]$len) {
    if ($len -lt 0x80) { return ,([byte]$len) }
    $tmp = $len
    $stack = New-Object System.Collections.Generic.List[byte]
    while ($tmp -gt 0) {
        $stack.Insert(0, [byte]($tmp -band 0xFF))
        $tmp = $tmp -shr 8
    }
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte](0x80 -bor $stack.Count))
    $out.AddRange($stack)
    return ,$out.ToArray()
}

function Encode-Integer([byte[]]$value) {
    # Strip leading zero bytes
    $i = 0
    while ($i -lt ($value.Length - 1) -and $value[$i] -eq 0) { $i++ }
    $stripped = New-Object byte[] ($value.Length - $i)
    [Array]::Copy($value, $i, $stripped, 0, $stripped.Length)
    # Prepend 0x00 if high bit set (force positive)
    if (($stripped[0] -band 0x80) -ne 0) {
        $tmp = New-Object byte[] ($stripped.Length + 1)
        [Array]::Copy($stripped, 0, $tmp, 1, $stripped.Length)
        $stripped = $tmp
    }
    $len = Encode-Length $stripped.Length
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte]0x02)
    $out.AddRange([byte[]]$len)
    $out.AddRange([byte[]]$stripped)
    return ,$out.ToArray()
}

function Encode-Sequence([byte[]]$content) {
    $len = Encode-Length $content.Length
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add([byte]0x30)
    $out.AddRange([byte[]]$len)
    $out.AddRange([byte[]]$content)
    return ,$out.ToArray()
}

$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $p = $rsa.ExportParameters($true)

    $contents = New-Object System.Collections.Generic.List[byte]
    # version INTEGER 0
    $contents.AddRange([byte[]]@(0x02, 0x01, 0x00))
    $contents.AddRange([byte[]](Encode-Integer $p.Modulus))
    $contents.AddRange([byte[]](Encode-Integer $p.Exponent))
    $contents.AddRange([byte[]](Encode-Integer $p.D))
    $contents.AddRange([byte[]](Encode-Integer $p.P))
    $contents.AddRange([byte[]](Encode-Integer $p.Q))
    $contents.AddRange([byte[]](Encode-Integer $p.DP))
    $contents.AddRange([byte[]](Encode-Integer $p.DQ))
    $contents.AddRange([byte[]](Encode-Integer $p.InverseQ))

    $pkcs1 = Encode-Sequence $contents.ToArray()

    # Wrap PKCS#1 in PKCS#8 PrivateKeyInfo:
    #   SEQUENCE {
    #     INTEGER 0,
    #     AlgorithmIdentifier { OID 1.2.840.113549.1.1.1 (rsaEncryption), NULL },
    #     OCTET STRING { <PKCS#1 RSAPrivateKey> }
    #   }
    $algId = [byte[]]@(0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00)

    $octetLen = Encode-Length $pkcs1.Length
    $octet = New-Object System.Collections.Generic.List[byte]
    $octet.Add([byte]0x04)
    $octet.AddRange([byte[]]$octetLen)
    $octet.AddRange([byte[]]$pkcs1)

    $p8Contents = New-Object System.Collections.Generic.List[byte]
    $p8Contents.AddRange([byte[]]@(0x02, 0x01, 0x00))   # version INTEGER 0
    $p8Contents.AddRange([byte[]]$algId)
    $p8Contents.AddRange([byte[]]$octet.ToArray())

    $der = Encode-Sequence $p8Contents.ToArray()

    $b64 = [Convert]::ToBase64String($der, [Base64FormattingOptions]::InsertLineBreaks)
    $pem = "-----BEGIN PRIVATE KEY-----`r`n$b64`r`n-----END PRIVATE KEY-----`r`n"
    Set-Content -Path $OutPath -Value $pem -Encoding Ascii
    Write-Host "Wrote PKCS#8 PEM private key: $OutPath ($($der.Length) DER bytes)"
}
finally {
    $rsa.Dispose()
}
