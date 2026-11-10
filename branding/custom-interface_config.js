// Appended by docker-jitsi-meet to its generated interface_config.js.
interfaceConfig.APP_NAME = 'MIREA Stream';
interfaceConfig.NATIVE_APP_NAME = 'MIREA Stream';
interfaceConfig.PROVIDER_NAME = 'MIREA Stream';
interfaceConfig.DEFAULT_WELCOME_PAGE_LOGO_URL = '/brand/logo-header.png';
interfaceConfig.DEFAULT_BACKGROUND = '#09265a';
interfaceConfig.JITSI_WATERMARK_LINK = 'https://mirea.stream/';
interfaceConfig.BRAND_WATERMARK_LINK = 'https://mirea.stream/';

// Use an additional stylesheet for the HOME page only. No Jitsi markup changes.
// The default welcome watermark is limited to just 71x32 pixels.
(function () {
    if (typeof document === 'undefined' || !document.head || document.getElementById('mirea-welcome-style')) {
        return;
    }
    var link = document.createElement('link');
    link.id = 'mirea-welcome-style';
    link.rel = 'stylesheet';
    link.href = '/brand/welcome.css';
    document.head.appendChild(link);
}());
