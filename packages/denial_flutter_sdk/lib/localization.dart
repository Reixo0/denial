/// Public Denial localization APIs.
library;

export 'l10n/generated/app_localizations.dart'
    show AppLocalizations, lookupAppLocalizations;
export 'l10n/generated/app_localizations_en.dart' show AppLocalizationsEn;
export 'l10n/generated/app_localizations_zh.dart' show AppLocalizationsZh;
export 'src/localization/denial_localizations.dart'
    show
        DenialLocalizationScope,
        DenialLocalizationsBuildContext,
        localizedBatteryLine,
        localizedBatteryState,
        localizedChargeProtocol,
        localizedClockDigits,
        localizedLongDate,
        localizedMonth,
        localizedShortDate,
        localizedThermalSensor,
        localizedTime,
        localizedWeekday,
        localizedWindowTitle;
