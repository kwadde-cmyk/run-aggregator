// Put your real Client ID and Secret here locally.
// Do NOT commit the secret to the repo.
// For now use the Web client you created.

class AuthConfig {
            static const String googleHealthClientId =
              '24711413447-190qjcrg3gc4cl8cs3njb5uuqiibhl3b.apps.googleusercontent.com';

            static const String googleHealthRedirectUri =
              'com.googleusercontent.apps.24711413447-190qjcrg3gc4cl8cs3njb5uuqiibhl3b:/oauthredirect';
  
         // TODO: Set this locally, never commit the real value
           static const String googleHealthClientSecret = '';


  static const List<String> googleHealthScopes = [
    'openid',
    'email',
    'https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly',
    'https://www.googleapis.com/auth/googlehealth.location.readonly',
    'https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly',
  ];
}
